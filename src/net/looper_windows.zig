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
    options: helpers.Options,
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
        var configured = options;
        configured.mux = options.mux orelse io_c.pp_mux_create(1) orelse return error.MuxFailure;
        self.* = .{
            .allocator = allocator,
            .options = configured,
            .owns_mux = options.mux == null,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        self.mutex.deinit();
        if (self.owns_mux) io_c.pp_mux_free(self.options.mux);
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        const until = if (max_wait_ms) |wait_ms|
            core.concurrency.deadlineAfterMs(core.monotonicNs(), wait_ms)
        else
            null;
        if (self.stopped) return false;
        while (true) {
            const now = core.monotonicNs();
            var deadline = until;
            var pending = self.timers.head;
            while (pending) |node| : (pending = node.next)
                deadline = @min(deadline orelse node.deadline_ns, node.deadline_ns);
            const timeout_ms: c_int = if (deadline) |value| blk: {
                const remaining = value -| now;
                const ms = remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0);
                break :blk @intCast(@min(ms, std.math.maxInt(c_int)));
            } else -1;
            self.mutex.lock();
            if (self.hasCallbackLocked()) {
                self.mutex.unlock();
                break;
            }
            self.waiting = true;
            self.mutex.unlock();
            var code: c_int = 0;
            const result = io_c.pp_mux_wait(self.options.mux, timeout_ms, &code);
            self.mutex.lock();
            self.waiting = false;
            self.mutex.unlock();
            if (result < 0) {
                failure.* = .{ .wait = if (code == 0) result else code };
                return false;
            }
            // Windows can report a timeout before the monotonic deadline.
            // Honor actual wake events immediately so the daemon can drain jobs.
            if (result > 0 or deadline == null or core.monotonicNs() >= deadline.?) break;
        }
        if (self.stopped) return false;
        for (0..self.options.max_read_count) |_| {
            self.mutex.lock();
            const node = self.callbacks.removeWhere({}, Received.isReady) orelse {
                self.mutex.unlock();
                break;
            };
            const side = node.side;
            // A protocol callback may detach its own side.
            side.retain();
            side.dispatched += 1;
            self.mutex.unlock();
            const keep = deliver(side, node.data.ptr, node.data.len, if (node.source) |*address| address else null, node.code);
            self.mutex.lock();
            side.reading = keep;
            self.freeReceived(node);
            self.mutex.unlock();
            side.release();
            if (self.stopped) return false;
        }
        const now = core.monotonicNs();
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) node.ready = node.deadline_ns <= now;
        // Newly scheduled tasks become eligible on the next iteration. Keep
        // uncalled tasks in the queue so callbacks can cancel or replace them.
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
        if (self.waiting) _ = io_c.pp_mux_wake(self.options.mux);
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

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        if (self.options.max_read_count == 0) return error.InvalidBuffers;
        if (self.stopped) return error.LooperUnavailable;
        const slot = &self.sides[@intFromEnum(std.meta.activeTag(arguments.pair))];
        if (slot.* != null) return error.SideAlreadyAttached;
        const side = try self.allocator.create(SideIO);
        errdefer self.allocator.destroy(side);
        side.* = .{ .allocator = self.allocator, .owner = self, .arguments = arguments };
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

    const SideIO = struct {
        allocator: std.mem.Allocator,
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
            self.allocator.destroy(self);
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

    fn deliver(
        self: *SideIO,
        bytes: [*c]const u8,
        length: usize,
        source: [*c]const io.SocketAddress,
        code: i32,
    ) bool {
        if (self.detached) return false;
        const arguments = self.arguments;
        const on_read = arguments.on_read;
        const on_failure = arguments.on_failure;
        if (code != 0) {
            if (on_failure) |callback| callback.call(.{ .io = .{
                .side = std.meta.activeTag(arguments.pair),
                .cause = if (code == io_c.WinrtSocketEOF) error.EndOfStream else error.LibcFailure,
                .code = if (code == io_c.WinrtSocketEOF) null else code,
            } });
            return false;
        }
        const packets = [_]io.Packet{if (length == 0) &.{} else bytes[0..length]};
        const addresses: ?[]const io.SocketAddress = if (source == null) null else source[0..1];
        const callback = on_read orelse return true;
        const action = callback.call(&packets, addresses) catch |err| {
            if (self.detached) return false;
            if (on_failure) |failure| failure.call(.{ .user = err });
            return false;
        };
        return action == .keep and !self.detached;
    }

    pub const testing = if (builtin.is_test) struct {
        pub const Side = SideIO;
        pub const receive = onReceive;
    } else void;
};
