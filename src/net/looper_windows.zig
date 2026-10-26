// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const core = @import("../core/exports.zig");
const ffi = @import("../c/exports.zig");
const io_c = ffi.io;

/// WinRT queues owned packets; loopOnce waits for work and dispatches callbacks
/// on its caller. Native callbacks signal the caller's existing mailbox wake event;
/// no socket readiness polling or separate timer thread is needed.
/// All public operations run on the looper thread (or before/after it runs).
/// Only native receives cross threads; mutex protects their queue and shared flags.
pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    mux: io_c.pp_mux,
    max_read_count: usize,
    owns_mux: bool,

    stopped: bool = false,
    sides: [2]?*SideIO = .{ null, null },
    mutex: core.Mutex = .{},
    waiting: bool = false,
    timers: core.Fifo(Scheduled) = .{},
    next_timer_id: u64 = 1,
    callbacks: core.Fifo(Received) = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) helpers.InitError!*WindowsLooper {
        const self = try allocator.create(WindowsLooper);
        errdefer allocator.destroy(self);
        const mux = options.mux orelse io_c.pp_mux_create(1) orelse return error.MuxFailure;
        self.* = .{
            .allocator = allocator,
            .mux = mux,
            .max_read_count = options.max_read_count,
            .owns_mux = options.mux == null,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        self.mutex.deinit();
        if (self.owns_mux) io_c.pp_mux_free(self.mux);
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        if (self.stopped) return false;
        if (self.waitForInput(max_wait_ms)) |code| {
            failure.* = .{ .wait = code };
            return false;
        }
        if (!self.dispatchInput()) return false;
        return self.dispatchTimers();
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        self.stopped = true;
        while (self.timers.take()) |node| self.allocator.destroy(node);
        try self.detach(.link);
        try self.detach(.tun);
    }

    /// Queue-confined, like the public timer API. Failed replacement preserves
    /// the previous task, and the caller's timer address is never retained.
    pub fn scheduleTimer(
        self: *WindowsLooper,
        timer: *io.Timer,
        delay_ms: u64,
        task: io.TimedTask,
    ) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .id = self.next_timer_id,
            .deadline_ns = core.concurrency.deadlineAfterMs(core.monotonicNs(), delay_ms),
            .task = task,
        };
        self.next_timer_id +%= 1;
        if (self.next_timer_id == 0) self.next_timer_id = 1;
        if (timer.id) |id| {
            if (self.timers.removeWhere(id, Scheduled.hasId)) |old| self.allocator.destroy(old);
        }
        self.timers.append(node);
        timer.id = node.id;
    }

    pub fn cancelTimer(self: *WindowsLooper, timer: *io.Timer) void {
        const id = timer.id orelse return;
        if (self.timers.removeWhere(id, Scheduled.hasId)) |node| self.allocator.destroy(node);
        timer.id = null;
    }

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        if (self.max_read_count == 0) return error.InvalidBuffers;
        if (self.stopped) return error.LooperUnavailable;
        const slot = &self.sides[@intFromEnum(std.meta.activeTag(arguments.pair))];
        if (slot.* != null) return error.SideAlreadyAttached;
        const side = try self.allocator.create(SideIO);
        errdefer self.allocator.destroy(side);
        side.* = .{ .owner = self, .arguments = arguments };
        slot.* = side;
        errdefer slot.* = null;
        switch (arguments.pair) {
            inline else => |wrapper| wrapper.setOnReceive(onReceive, side) catch return error.LooperUnavailable,
        }
    }

    /// Native sockets own copied packets and serialize async writes.
    pub fn write(
        self: *WindowsLooper,
        packets: io.Packets,
        tag: io.Side,
        destination: ?io.SocketAddress,
    ) helpers.WriteError!void {
        if (packets.len == 0) return;
        const side = try self.getSide(tag);
        if (side.arguments.pair == .link and side.arguments.pair.link.unconnected and destination == null)
            return error.MissingDestination;
        for (packets) |packet| {
            const result = switch (side.arguments.pair) {
                .link => |socket| socket.write(packet, destination),
                .tun => |tun| tun.write(packet),
            };
            if (result != 0) {
                // Native and synchronous write errors use the same input queue.
                _ = onReceive(side, null, 0, null, result);
                return;
            }
        }
    }

    /// Native writes start at submission; nothing needs a readiness-driven flush.
    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        return null;
    }

    pub fn detach(self: *WindowsLooper, tag: io.Side) helpers.DetachError!void {
        const slot = &self.sides[@intFromEnum(tag)];
        const side = slot.* orelse return;
        slot.* = null;
        side.detached = true; // Dispatch/lifetime state belongs to the looper.
        // Drain without the queue lock: a native callback may still be enqueuing.
        switch (side.arguments.pair) {
            inline else => |wrapper| {
                wrapper.stopWrites();
                wrapper.setOnReceive(null, null) catch unreachable;
            },
        }
        self.mutex.lock();
        while (self.callbacks.removeWhere(side, Received.belongsTo)) |node| self.freeReceived(node);
        self.mutex.unlock();
        core.logging.writef(.info, "Windows looper {s}: queued={}, dispatched={}, dropped={}, reading={}", .{
            @tagName(tag), side.queued, side.dispatched, side.dropped, side.reading,
        });
        side.release();
    }

    pub fn isAttached(self: *const WindowsLooper, side: io.Side) bool {
        return self.sides[@intFromEnum(side)] != null;
    }

    pub fn resumeReading(self: *WindowsLooper, side: io.Side) helpers.SubmissionError!void {
        const attachment = self.getSide(side) catch return error.LooperUnavailable;
        self.mutex.lock();
        attachment.reading = true;
        self.mutex.unlock();
        if (attachment.arguments.pair == .link)
            attachment.arguments.pair.link.resumeReading() catch return error.LooperUnavailable;
    }

    fn getSide(self: *WindowsLooper, tag: io.Side) error{ LooperUnavailable, SideNotAttached }!*SideIO {
        if (self.stopped) return error.LooperUnavailable;
        return self.sides[@intFromEnum(tag)] orelse return error.SideNotAttached;
    }

    fn waitForInput(self: *WindowsLooper, max_wait_ms: ?u32) ?c_int {
        var deadline: ?u64 = if (max_wait_ms) |ms| core.concurrency.deadlineAfterMs(core.monotonicNs(), ms) else null;
        // Only the looper mutates timers, so the deadline stays fixed while waiting.
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next)
            deadline = @min(deadline orelse node.deadline_ns, node.deadline_ns);

        while (self.beginWait()) {
            const timeout_ms: c_int = if (deadline) |until| blk: {
                const remaining = until -| core.monotonicNs();
                const ms = remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0);
                break :blk @intCast(@min(ms, std.math.maxInt(c_int)));
            } else -1;
            var code: c_int = 0;
            const result = io_c.pp_mux_wait(self.mux, timeout_ms, &code);
            self.mutex.lock();
            self.waiting = false;
            self.mutex.unlock();
            if (result < 0) return if (code == 0) result else code;
            // Retry early Windows timeouts; mailbox wakes must return to the daemon.
            if (result > 0 or deadline == null or core.monotonicNs() >= deadline.?) break;
        }
        return null;
    }

    fn beginWait(self: *WindowsLooper) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.hasCallbackLocked()) return false;
        self.waiting = true;
        return true;
    }

    fn dispatchInput(self: *WindowsLooper) bool {
        for (0..self.max_read_count) |_| {
            const node = self.takeInput() orelse break;
            self.dispatch(node);
            if (self.stopped) return false;
        }
        return true;
    }

    fn takeInput(self: *WindowsLooper) ?*Received {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.callbacks.removeWhere({}, Received.isReady);
    }

    fn dispatch(self: *WindowsLooper, node: *Received) void {
        const side = node.side;
        // A protocol callback may detach its own side; release after freeing input.
        side.retain();
        defer side.release();
        side.dispatched += 1;
        const keep = node.deliver();
        self.mutex.lock();
        defer self.mutex.unlock();
        side.reading = keep;
        self.freeReceived(node);
    }

    fn dispatchTimers(self: *WindowsLooper) bool {
        const now = core.monotonicNs();
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) node.ready = node.deadline_ns <= now;
        // Newly scheduled tasks become eligible on the next iteration. Keep
        // uncalled tasks queued so callbacks can cancel or replace them.
        while (self.timers.removeWhere({}, Scheduled.isReady)) |node| {
            const task = node.task;
            self.allocator.destroy(node);
            task.call();
            if (self.stopped) return false;
        }
        return true;
    }

    // Called with mutex held. Queued input covers notifications before
    // the wait; signalling only a current waiter avoids leaving stale wake events.
    fn notifyLocked(self: *WindowsLooper) void {
        if (self.waiting) _ = io_c.pp_mux_wake(self.mux);
    }

    const Scheduled = struct {
        id: u64,
        deadline_ns: u64,
        task: io.TimedTask,
        ready: bool = false,
        next: ?*Scheduled = null,

        fn hasId(self: *const Scheduled, id: u64) bool {
            return self.id == id;
        }

        fn isReady(self: *const Scheduled, _: void) bool {
            return self.ready;
        }
    };

    const SideIO = struct {
        owner: *WindowsLooper,
        arguments: helpers.AttachArguments,
        reading: bool = true,
        queued: u64 = 0,
        dispatched: u64 = 0,
        dropped: u64 = 0,
        allocation_failure: ?Received = null,
        // Ownership and in-progress dispatches are confined to the looper thread.
        references: usize = 1,
        detached: bool = false,

        fn retain(self: *SideIO) void {
            self.references += 1;
        }

        fn release(self: *SideIO) void {
            self.references -= 1;
            if (self.references != 0) return;
            switch (self.arguments.pair) {
                inline else => |wrapper| wrapper.cleanup(),
            }
            self.owner.allocator.destroy(self);
        }
    };

    const Received = struct {
        side: *SideIO,
        data: []const u8 = &.{},
        source: ?io.SocketAddress = null,
        code: i32 = 0,
        next: ?*Received = null,

        fn isReady(self: *const Received, _: void) bool {
            return self.code != 0 or self.side.reading;
        }

        fn deliver(self: *const Received) bool {
            const side = self.side;
            if (side.detached) return false;
            const arguments = side.arguments;
            if (self.code != 0) {
                if (arguments.on_failure) |callback| callback.call(.{ .io = .{
                    .side = std.meta.activeTag(arguments.pair),
                    .cause = if (self.code == io_c.WinrtSocketEOF) error.EndOfStream else error.LibcFailure,
                    .code = if (self.code == io_c.WinrtSocketEOF) null else self.code,
                } });
                return false;
            }
            const callback = arguments.on_read orelse return true;
            const addresses: ?[1]io.SocketAddress = if (self.source) |address| .{address} else null;
            const action = callback.call(&.{self.data}, if (addresses) |*value| value else null) catch |err| {
                if (side.detached) return false;
                if (arguments.on_failure) |failure| failure.call(.{ .user = err });
                return false;
            };
            return action == .keep and !side.detached;
        }

        fn belongsTo(self: *const Received, side: *SideIO) bool {
            return self.side == side;
        }
    };

    fn hasCallbackLocked(self: *WindowsLooper) bool {
        var pending = self.callbacks.head;
        while (pending) |node| : (pending = node.next) {
            if (node.isReady({})) return true;
        }
        return false;
    }

    fn freeReceived(self: *WindowsLooper, node: *Received) void {
        const side = node.side;
        if (side.allocation_failure != null and node == &side.allocation_failure.?) return;
        self.allocator.free(node.data);
        self.allocator.destroy(node);
    }

    fn onReceive(
        context: ?*anyopaque,
        bytes: [*c]const u8,
        length: usize,
        source: [*c]const io.SocketAddress,
        code: i32,
    ) callconv(.c) bool {
        const side: *SideIO = @ptrCast(@alignCast(context.?));
        const self = side.owner;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (side.allocation_failure != null) return false;
        // TUN input keeps arriving while paused. Drop it before allocating;
        // socket input must retain in-flight TCP bytes until resumeReading().
        if (code == 0 and !side.reading and side.arguments.pair == .tun) {
            side.dropped += 1;
            return false;
        }
        const node = self.copyReceived(side, if (length == 0) &.{} else bytes[0..length], source, code) catch blk: {
            // Reserve failure delivery without allocating on the OOM path.
            side.allocation_failure = .{ .side = side, .code = -2147024882 }; // E_OUTOFMEMORY
            break :blk &side.allocation_failure.?;
        };
        self.callbacks.append(node);
        side.queued += 1;
        self.notifyLocked();
        return side.reading and side.allocation_failure == null and code == 0;
    }

    fn copyReceived(self: *WindowsLooper, side: *SideIO, bytes: []const u8, source: [*c]const io.SocketAddress, code: i32) !*Received {
        const node = try self.allocator.create(Received);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .side = side,
            .data = try self.allocator.dupe(u8, bytes),
            .source = if (source == null) null else source[0],
            .code = code,
        };
        return node;
    }

    pub const testing = if (builtin.is_test) struct {
        pub const Side = SideIO;
        pub const receive = onReceive;
    } else void;
};
