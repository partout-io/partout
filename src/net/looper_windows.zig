// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const core = @import("../core/exports.zig");

/// WinRT queues owned packets; loopOnce dispatches callbacks on its caller.
/// Lifecycle operations and loopOnce are caller-serialized, including detach.
pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    options: helpers.Options,

    stopped: bool = false,
    sides: [2]?*SideIO = .{ null, null },
    mutex: core.Mutex = .{},
    timer_alarm: core.RunAfter = .{},
    alarm_deadline_ns: ?u64 = null,
    timer_condition: core.Condition = .{},
    timers: core.Fifo(Scheduled) = .{},
    next_timer_id: u64 = 1,
    callbacks: core.Fifo(Received) = .{},
    testing_before_write: if (builtin.is_test) ?io.TimedTask else void = if (builtin.is_test) null else {},

    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) helpers.InitError!*WindowsLooper {
        const self = try allocator.create(WindowsLooper);
        self.* = .{
            .allocator = allocator,
            .options = options,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        // The alarm borrows only self, never a timer's task context.
        self.timer_alarm.deinit();
        self.timer_condition.deinit();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Keep the normal driver nonblocking: its mailbox wake is independent
        // of this looper. Explicit bounded polls may wait for the timer alarm.
        if (max_wait_ms) |wait_ms| {
            const until = core.concurrency.deadlineAfterMs(core.monotonicNs(), wait_ms);
            while (!self.stopped and !self.hasDueTimerLocked() and !self.hasCallbackLocked()) {
                if (core.monotonicNs() >= until) break;
                self.timer_condition.waitUntil(&self.mutex, until);
            }
        }
        if (self.stopped) return false;
        for (0..self.options.max_read_count) |_| {
            const node = self.callbacks.removeWhere({}, Received.isReady) orelse break;
            const side = node.side;
            self.mutex.unlock();
            const keep = deliver(side, node.data.ptr, node.data.len, if (node.source) |*address| address else null, node.code);
            self.mutex.lock();
            side.reading = keep;
            self.freeReceived(node);
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
            self.mutex.unlock();
            task.call();
            self.mutex.lock();
            if (self.stopped) return false;
        }
        self.armTimerLocked();
        return true;
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        self.mutex.lock();
        self.stopped = true;
        self.timer_alarm.cancel();
        self.alarm_deadline_ns = null;
        while (self.timers.take()) |node| self.allocator.destroy(node);
        self.timer_condition.broadcast();
        self.mutex.unlock();
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
    ) io.SubmissionError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        errdefer self.allocator.destroy(node);
        self.timer_alarm.start() catch return error.LooperUnavailable;
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
        self.armTimerLocked();
    }

    pub fn cancelTimer(self: *WindowsLooper, timer: *io.Timer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = timer.id orelse return;
        if (self.timers.removeWhere(id, Scheduled.hasId)) |node| self.allocator.destroy(node);
        timer.id = null;
        self.armTimerLocked();
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

    fn hasDueTimerLocked(self: *WindowsLooper) bool {
        const now = core.monotonicNs();
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) {
            if (node.deadline_ns <= now) return true;
        }
        return false;
    }

    fn armTimerLocked(self: *WindowsLooper) void {
        var deadline: ?u64 = null;
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) {
            deadline = @min(deadline orelse node.deadline_ns, node.deadline_ns);
        }
        if (deadline == self.alarm_deadline_ns) return;
        self.alarm_deadline_ns = deadline;
        if (deadline) |value| {
            const ns = value -| core.monotonicNs();
            const ms = ns / std.time.ns_per_ms + @intFromBool(ns % std.time.ns_per_ms != 0);
            // start() succeeded before publishing any scheduled entry.
            self.timer_alarm.scheduleReplacing(ms, onTimerAlarm, self) catch unreachable;
        } else self.timer_alarm.cancel();
    }

    fn onTimerAlarm(context: ?*anyopaque) void {
        const self: *WindowsLooper = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.timer_condition.broadcast();
    }

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
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
            inline else => |wrapper| try wrapper.setOnReceive(onReceive, side),
        }
    }

    /// Writes complete before returning, so there is no separate flush queue.
    pub fn write(
        self: *WindowsLooper,
        packets: io.Packets,
        tag: io.Side,
        destination: ?io.SocketAddress,
    ) helpers.WriteError!void {
        if (packets.len == 0) return;
        const side = try self.acquireSide(tag);
        defer side.release();
        if (side.arguments.pair == .link and side.arguments.pair.link.unconnected and destination == null)
            return error.MissingDestination;
        for (packets) |packet| {
            if (side.detached.load(.acquire)) return error.SideNotAttached;
            if (builtin.is_test) if (self.testing_before_write) |hook| hook.call();
            const result = switch (side.arguments.pair) {
                .link => |socket| try socket.write(packet, destination),
                .tun => |tun| try tun.write(packet),
            };
            if (result) |failure| {
                if (side.detached.load(.acquire)) return error.SideNotAttached;
                // Queue directly; the retained side and queue lock cover detach.
                _ = onReceive(side, null, 0, null, failure.io.code.?);
                return;
            }
        }
    }

    /// Socket writes are submitted and completed by write().
    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        return null;
    }

    pub fn detach(self: *WindowsLooper, tag: io.Side) helpers.DetachError!void {
        self.mutex.lock();
        const slot = &self.sides[@intFromEnum(tag)];
        const side = slot.* orelse {
            self.mutex.unlock();
            return;
        };
        slot.* = null;
        side.detached.store(true, .release);
        switch (side.arguments.pair) {
            inline else => |wrapper| wrapper.stopWrites(),
        }
        while (self.callbacks.removeWhere(side, Received.belongsTo)) |node| self.freeReceived(node);
        self.mutex.unlock();
        // Never hold the looper lock while draining native callbacks: a consumer
        // may reenter detach. Writers retain the side until their batch exits.
        switch (side.arguments.pair) {
            inline else => |wrapper| wrapper.setOnReceive(null, null) catch unreachable,
        }
        side.release();
    }

    pub fn isAttached(self: *const WindowsLooper, side: io.Side) bool {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        return self.sides[@intFromEnum(side)] != null;
    }

    pub fn resumeReading(self: *WindowsLooper, side: io.Side) io.SubmissionError!void {
        const attachment = self.acquireSide(side) catch return error.LooperUnavailable;
        defer attachment.release();
        self.mutex.lock();
        attachment.reading = true;
        self.timer_condition.broadcast();
        self.mutex.unlock();
        // Re-registering must not race with detach clearing the callback.
        if (attachment.arguments.pair == .link) try attachment.arguments.pair.link.resumeReading();
    }

    fn acquireSide(self: *WindowsLooper, tag: io.Side) error{ LooperUnavailable, SideNotAttached }!*SideIO {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.LooperUnavailable;
        const side = self.sides[@intFromEnum(tag)] orelse return error.SideNotAttached;
        side.retain();
        return side;
    }

    const SideIO = struct {
        allocator: std.mem.Allocator,
        owner: *WindowsLooper,
        arguments: helpers.AttachArguments,
        reading: bool = true,
        allocation_failure: ?Received = null,
        references: std.atomic.Value(usize) = .init(1),
        detached: std.atomic.Value(bool) = .init(false),

        fn retain(self: *SideIO) void {
            _ = self.references.fetchAdd(1, .monotonic);
        }

        fn release(self: *SideIO) void {
            if (self.references.fetchSub(1, .acq_rel) != 1) return;
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
        if (side.allocation_failure == null or node != &side.allocation_failure.?) {
            self.allocator.free(node.data);
            self.allocator.destroy(node);
        }
        side.release();
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
        if (side.detached.load(.acquire) or side.allocation_failure != null) return false;
        const node = self.copyReceived(side, if (length == 0) &.{} else bytes[0..length], source, code) catch blk: {
            // Reserve failure delivery without allocating on the OOM path.
            side.allocation_failure = .{ .side = side, .code = -2147024882 }; // E_OUTOFMEMORY
            break :blk &side.allocation_failure.?;
        };
        side.retain();
        self.callbacks.append(node);
        self.timer_condition.broadcast();
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
        if (self.detached.load(.acquire)) return false;
        const arguments = self.arguments;
        const on_read = arguments.on_read;
        const on_failure = arguments.on_failure;
        if (code != 0) {
            if (on_failure) |callback| callback.call(.{ .io = .{
                .side = std.meta.activeTag(arguments.pair),
                .cause = if (code == 1) error.EndOfStream else error.LibcFailure,
                .code = if (code == 1) null else code,
            } });
            return false;
        }
        const packets = [_]io.Packet{if (length == 0) &.{} else bytes[0..length]};
        const addresses: ?[]const io.SocketAddress = if (source == null) null else source[0..1];
        if (on_read) |callback| {
            const action = callback.call(&packets, addresses) catch |err| {
                if (self.detached.load(.acquire)) return false;
                if (on_failure) |failure| failure.call(.{ .user = err });
                return false;
            };
            return action == .keep and !self.detached.load(.acquire);
        }
        return true;
    }
};
