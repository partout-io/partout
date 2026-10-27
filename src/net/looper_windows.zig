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
    sides: [2]Attachment,
    mutex: core.Mutex,
    on_receive: io_common.PacketReceiveCallback,
    receive_context: ?*anyopaque,
    timers: core.Fifo(Scheduled),
    next_timer: u64,
    max_read_count: usize,
    stopped: bool,

    pub const Attachment = struct {
        owner: *WindowsLooper,
        side: io.Side,
        generation: u64,
        reading: bool,
        arguments: ?helpers.AttachArguments,

        fn init(owner: *WindowsLooper, side: io.Side) Attachment {
            return .{
                .owner = owner,
                .side = side,
                .generation = 0,
                .reading = true,
                .arguments = null,
            };
        }

        pub fn receipt(attachment: *Attachment, bytes: [*c]const u8, length: usize, source: [*c]const io.SocketAddress, code: i32) ?helpers.PacketReceipt {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (attachment.arguments == null or (code == 0 and !attachment.reading and attachment.side == .tun)) {
                return null;
            }
            return .{
                .side = attachment.side,
                .generation = attachment.generation,
                .bytes = if (length > 0) bytes[0..length] else &.{},
                .source = if (source != null) source[0] else null,
                .code = code,
            };
        }

        pub fn keepReading(attachment: *Attachment, event: helpers.PacketReceipt) bool {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            return attachment.arguments != null and attachment.generation == event.generation and attachment.reading and event.code == 0;
        }
    };
    const Scheduled = struct {
        id: u64,
        deadline: u64,
        task: io.TimedTask,
        ready: bool,
        next: ?*Scheduled,
        fn hasId(self: *const Scheduled, id: u64) bool {
            return self.id == id;
        }

        fn isReady(self: *const Scheduled, _: void) bool {
            return self.ready;
        }
    };

    pub fn create(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!*WindowsLooper {
        if (!build_options.winrt) return error.MuxFailure;
        const mux = options.mux orelse return error.MuxFailure;
        const self = try allocator.create(WindowsLooper);
        self.* = .{
            .allocator = allocator,
            .mux = mux,
            .sides = .{
                Attachment.init(self, .link),
                Attachment.init(self, .tun),
            },
            .mutex = .{},
            .max_read_count = options.max_read_count,
            .on_receive = options.on_receive,
            .receive_context = options.receive_context,
            .timers = .{},
            .next_timer = 1,
            .stopped = false,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        self.mutex.deinit();
        self.allocator.destroy(self);
    }

    pub fn canReceivePackets(self: *WindowsLooper, event: helpers.PacketReceipt) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const side = &self.sides[@intFromEnum(event.side)];
        return side.arguments == null or
            side.generation != event.generation or
            event.code != 0 or side.reading;
    }

    pub fn receivePackets(self: *WindowsLooper, event: helpers.PacketReceipt) void {
        const side = &self.sides[@intFromEnum(event.side)];
        if (side.generation != event.generation) return;
        const arguments = side.arguments orelse return;
        if (event.code != 0) {
            if (arguments.on_failure) |callback| callback.call(.{ .io = .{
                .side = event.side,
                .cause = if (event.code == c.WinrtEOF) error.EndOfStream else error.LibcFailure,
                .code = if (event.code == c.WinrtEOF) null else event.code,
            } });
            self.setReading(side, event.generation, false);
            return;
        }
        const on_read = arguments.on_read orelse return;
        const addresses: ?[]const io.SocketAddress = if (event.source) |value| &.{value} else null;
        const action = on_read.call(&.{event.bytes}, addresses) catch |err| {
            if (side.generation == event.generation) {
                if (arguments.on_failure) |failure| failure.call(.{ .user = err });
                self.setReading(side, event.generation, false);
            }
            return;
        };
        self.setReading(side, event.generation, action == .keep);
    }

    fn setReading(self: *WindowsLooper, side: *Attachment, generation: u64, reading: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (side.arguments != null and side.generation == generation) side.reading = reading;
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
        node.* = .{
            .id = self.next_timer,
            .deadline = core.concurrency.deadlineAfterMs(core.monotonicNs(), delay_ms),
            .task = task,
            .ready = false,
            .next = null,
        };
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
        const attachment = &self.sides[@intFromEnum(tag)];
        self.mutex.lock();
        if (attachment.arguments != null) {
            self.mutex.unlock();
            return error.SideAlreadyAttached;
        }
        attachment.generation +%= 1;
        attachment.arguments = arguments;
        attachment.reading = true;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.setOnReceive(self.on_receive, attachment) catch {
                self.mutex.lock();
                attachment.arguments = null;
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
        if (arguments.pair == .link and arguments.pair.link.native.unconnected and destination == null) return error.MissingDestination;
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
