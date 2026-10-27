// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

//! Native producers feed the caller's mailbox directly. Protocol
//! processing, backpressure and timers remain on the Zig caller.
const std = @import("std");
const build_options = @import("build_options");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const io_common = @import("io_common.zig");
const ffi = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const c = ffi.io;

pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    mux: c.pp_mux,
    owns_mux: bool,
    sides: [2]Attachment = .{ .{}, .{} },
    mutex: core.Mutex = .{},
    on_receive: io_common.PacketReceiveCallback = null,
    receive_context: ?*anyopaque = null,
    timers: core.Fifo(Scheduled) = .{},
    next_timer: u64 = 1,
    max_read_count: usize,
    stopped: bool = false,

    pub const Attachment = struct {
        owner: *WindowsLooper = undefined,
        tag: io.Side = .link,
        arguments: ?helpers.AttachArguments = null,
        generation: u64 = 0,
        reading: bool = true,
        allocation_failure: enum { none, pending, delivered } = .none,

        pub fn input(side: *Attachment, bytes: [*c]const u8, length: usize, source: [*c]const io.SocketAddress, code: i32) ?helpers.PacketSubmission {
            const self = side.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (side.arguments == null or side.allocation_failure != .none or (code == 0 and !side.reading and side.tag == .tun)) {
                return null;
            }
            return .{
                .side = side.tag,
                .generation = side.generation,
                .bytes = if (length == 0) &.{} else bytes[0..length],
                .source = if (source == null) null else @as(*const io.SocketAddress, @ptrCast(source)).*,
                .code = code,
            };
        }

        pub fn keepReading(side: *Attachment, event: helpers.PacketSubmission) bool {
            const self = side.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            return side.arguments != null and side.generation == event.generation and side.reading and event.code == 0;
        }
    };
    const Scheduled = struct {
        id: u64,
        deadline: u64,
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

    pub fn create(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!*WindowsLooper {
        if (!build_options.winrt) return error.MuxFailure;
        const self = try allocator.create(WindowsLooper);
        errdefer allocator.destroy(self);
        const mux = options.mux orelse c.pp_mux_create(1) orelse return error.MuxFailure;
        errdefer if (options.mux == null) c.pp_mux_free(mux);
        self.* = .{ .allocator = allocator, .mux = mux, .owns_mux = options.mux == null, .max_read_count = options.max_read_count, .on_receive = options.on_receive, .receive_context = options.receive_context };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        self.mutex.deinit();
        if (self.owns_mux) c.pp_mux_free(self.mux);
        self.allocator.destroy(self);
    }

    pub fn failAllocation(self: *WindowsLooper, event: helpers.PacketSubmission) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const side = &self.sides[@intFromEnum(event.side)];
        if (side.arguments == null or side.generation != event.generation or side.allocation_failure != .none) {
            return false;
        }
        // Reserve terminal failure delivery in the attachment itself: this
        // path must work even when neither a node nor packet can be allocated.
        side.allocation_failure = .pending;
        side.reading = false;
        return true;
    }

    pub fn inputReady(self: *WindowsLooper, event: helpers.PacketSubmission) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const side = &self.sides[@intFromEnum(event.side)];
        return side.arguments == null or side.generation != event.generation or event.code != 0 or side.reading;
    }

    pub fn deliver(self: *WindowsLooper, event: helpers.PacketSubmission) void {
        const side = &self.sides[@intFromEnum(event.side)];
        if (side.arguments == null or side.generation != event.generation) return;
        const arguments = side.arguments.?;
        if (event.code != 0) {
            if (arguments.on_failure) |callback| callback.call(.{ .io = .{
                .side = event.side,
                .cause = if (event.code == c.WinrtEOF) error.EndOfStream else error.LibcFailure,
                .code = if (event.code == c.WinrtEOF) null else event.code,
            } });
            self.pause(side, event.generation, false);
            return;
        }
        const callback = arguments.on_read orelse return;
        const address: ?[1]io.SocketAddress = if (event.source) |value| .{value} else null;
        const action = callback.call(&.{event.bytes}, if (address) |*value| value else null) catch |err| {
            if (side.arguments != null and side.generation == event.generation) {
                if (arguments.on_failure) |failure| failure.call(.{ .user = err });
                self.pause(side, event.generation, false);
            }
            return;
        };
        self.pause(side, event.generation, action == .keep);
    }

    fn pause(self: *WindowsLooper, side: *Attachment, generation: u64, keep: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (side.arguments != null and side.generation == generation) side.reading = keep;
    }

    pub fn dispatchFailures(self: *WindowsLooper) void {
        for (&self.sides) |*side| {
            self.mutex.lock();
            const event: ?helpers.PacketSubmission = if (side.arguments != null and side.allocation_failure == .pending) .{
                .side = side.tag,
                .generation = side.generation,
                .code = -2147024882, // E_OUTOFMEMORY
            } else null;
            if (event != null) side.allocation_failure = .delivered;
            self.mutex.unlock();
            if (event) |value| self.deliver(value);
            if (self.stopped) return;
        }
    }

    pub fn loopOnce(self: *WindowsLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        if (self.stopped) return false;
        var deadline: ?u64 = if (max_wait_ms) |ms| core.concurrency.deadlineAfterMs(core.monotonicNs(), ms) else null;
        var timer = self.timers.head;
        while (timer) |node| : (timer = node.next) deadline = @min(deadline orelse node.deadline, node.deadline);
        while (true) {
            const timeout: c_int = if (deadline) |until| blk: {
                const remaining = until -| core.monotonicNs();
                const ms = remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0);
                break :blk @intCast(@min(ms, std.math.maxInt(c_int)));
            } else -1;
            var code: c_int = 0;
            const result = c.pp_mux_wait(self.mux, timeout, &code);
            if (result < 0) {
                failure.* = .{ .wait = if (code == 0) result else code };
                return false;
            }
            if (result > 0 or deadline == null or core.monotonicNs() >= deadline.?) break;
        }
        const now = core.monotonicNs();
        timer = self.timers.head;
        while (timer) |node| : (timer = node.next) node.ready = node.deadline <= now;
        while (self.timers.removeWhere({}, Scheduled.isReady)) |node| {
            const task = node.task;
            self.allocator.destroy(node);
            task.call();
            if (self.stopped) return false;
        }
        return true;
    }

    pub fn scheduleTimer(self: *WindowsLooper, token: *io.Timer, delay_ms: u64, task: io.TimedTask) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        node.* = .{ .id = self.next_timer, .deadline = core.concurrency.deadlineAfterMs(core.monotonicNs(), delay_ms), .task = task };
        self.next_timer +%= 1;
        if (self.next_timer == 0) self.next_timer = 1;
        self.cancelTimer(token);
        self.timers.append(node);
        token.id = node.id;
    }

    pub fn cancelTimer(self: *WindowsLooper, token: *io.Timer) void {
        const id = token.id orelse return;
        if (self.timers.removeWhere(id, Scheduled.hasId)) |node| self.allocator.destroy(node);
        token.id = null;
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        self.stopped = true;
        while (self.timers.take()) |node| self.allocator.destroy(node);
        try self.detach(.link);
        try self.detach(.tun);
    }

    pub fn attach(self: *WindowsLooper, arguments: helpers.AttachArguments) helpers.AttachError!void {
        if (self.max_read_count == 0) return error.InvalidBuffers;
        if (self.on_receive == null) return error.LooperUnavailable;
        if (self.stopped) return error.LooperUnavailable;
        const tag = std.meta.activeTag(arguments.pair);
        const side = &self.sides[@intFromEnum(tag)];
        self.mutex.lock();
        if (side.arguments != null) {
            self.mutex.unlock();
            return error.SideAlreadyAttached;
        }
        side.owner = self;
        side.tag = tag;
        side.generation +%= 1;
        side.arguments = arguments;
        side.reading = true;
        side.allocation_failure = .none;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.setOnReceive(self.on_receive, side) catch {
                self.mutex.lock();
                side.arguments = null;
                self.mutex.unlock();
                return error.LooperUnavailable;
            },
        }
    }

    pub fn detach(self: *WindowsLooper, tag: io.Side) helpers.DetachError!void {
        const side = &self.sides[@intFromEnum(tag)];
        self.mutex.lock();
        const arguments = side.arguments orelse {
            self.mutex.unlock();
            return;
        };
        side.arguments = null;
        side.generation +%= 1;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.cleanup(),
        }
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn isAttached(self: *const WindowsLooper, tag: io.Side) bool {
        return self.sides[@intFromEnum(tag)].arguments != null;
    }

    pub fn resumeReading(self: *WindowsLooper, tag: io.Side) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const side = &self.sides[@intFromEnum(tag)];
        const arguments = side.arguments orelse return error.LooperUnavailable;
        self.mutex.lock();
        if (side.allocation_failure != .none) {
            self.mutex.unlock();
            return error.LooperUnavailable;
        }
        side.reading = true;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.resumeReading() catch return error.LooperUnavailable,
        }
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn write(self: *WindowsLooper, packets: io.Packets, tag: io.Side, destination: ?io.SocketAddress) helpers.WriteError!void {
        if (packets.len == 0) return;
        if (self.stopped) return error.LooperUnavailable;
        const side = &self.sides[@intFromEnum(tag)];
        const arguments = side.arguments orelse return error.SideNotAttached;
        if (arguments.pair == .link and arguments.pair.link.unconnected and destination == null) return error.MissingDestination;
        for (packets) |packet| {
            const result = switch (arguments.pair) {
                inline else => |value| value.write(packet, destination),
            };
            if (result != 0) {
                if (self.on_receive) |callback| _ = callback(side, null, 0, null, result);
                return;
            }
        }
    }

    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        return null;
    }
};
