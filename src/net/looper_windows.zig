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

        pub fn makeReceipt(attachment: *Attachment, bytes: [*c]const u8, length: usize, source: [*c]const io.SocketAddress, code: i32) ?helpers.PacketReceipt {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!attachment.acceptsReceipt(code)) return null;
            return .{
                .side = attachment.side,
                .generation = attachment.generation,
                .bytes = if (length > 0) bytes[0..length] else &.{},
                .source = if (source != null) source[0] else null,
                .code = code,
            };
        }

        // Called while holding the owner's mutex. Paused TUN input is dropped;
        // link input stays queued in the mailbox, and failures remain eligible.
        fn acceptsReceipt(attachment: *const Attachment, code: i32) bool {
            return attachment.arguments != null and
                (code != 0 or attachment.reading or attachment.side == .link);
        }

        pub fn keepReading(attachment: *Attachment, receipt: helpers.PacketReceipt) bool {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            return attachment.arguments != null and attachment.generation == receipt.generation and attachment.reading and receipt.code == 0;
        }

        fn canReceivePackets(attachment: *Attachment, receipt: helpers.PacketReceipt) bool {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            return attachment.arguments == null or
                attachment.generation != receipt.generation or
                receipt.code != 0 or attachment.reading;
        }

        fn setReading(attachment: *Attachment, generation: u64, reading: bool) void {
            const self = attachment.owner;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (attachment.arguments != null and attachment.generation == generation) attachment.reading = reading;
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

    pub fn canReceivePackets(self: *WindowsLooper, receipt: helpers.PacketReceipt) bool {
        return self.sides[@intFromEnum(receipt.side)].canReceivePackets(receipt);
    }

    pub fn receivePackets(self: *WindowsLooper, receipt: helpers.PacketReceipt) void {
        const attachment = &self.sides[@intFromEnum(receipt.side)];
        if (attachment.generation != receipt.generation) return;
        const arguments = attachment.arguments orelse return;
        if (receipt.code != 0) {
            if (arguments.on_failure) |callback| callback.call(.{ .io = .{
                .side = receipt.side,
                .cause = if (receipt.code == c.WinrtEOF) error.EndOfStream else error.LibcFailure,
                .code = if (receipt.code == c.WinrtEOF) null else receipt.code,
            } });
            attachment.setReading(receipt.generation, false);
            return;
        }
        const on_read = arguments.on_read orelse return;
        const addresses: ?[]const io.SocketAddress = if (receipt.source) |value| &.{value} else null;
        const action = on_read.call(&.{receipt.bytes}, addresses) catch |err| {
            if (attachment.generation == receipt.generation) {
                if (arguments.on_failure) |failure| failure.call(.{ .user = err });
                attachment.setReading(receipt.generation, false);
            }
            return;
        };
        attachment.setReading(receipt.generation, action == .keep);
    }

    pub fn loopOnce(self: *WindowsLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        if (self.stopped) return false;
        const deadline = self.nextWaitDeadline(max_wait_ms);
        while (true) {
            var code: c_int = 0;
            const result = c.pp_mux_wait(self.mux, remainingWaitMs(deadline), &code);
            if (result < 0) {
                failure.* = .{ .wait = if (code == 0) result else code };
                return false;
            }
            if (waitCompleted(result, deadline)) break;
        }
        return self.dispatchExpiredTimers();
    }

    fn nextWaitDeadline(self: *const WindowsLooper, max_wait_ms: ?u32) ?u64 {
        var deadline: ?u64 = if (max_wait_ms) |ms| core.concurrency.deadlineAfterMs(core.monotonicNs(), ms) else null;
        var timer = self.timers.head;
        while (timer) |node| : (timer = node.next) deadline = @min(deadline orelse node.deadline, node.deadline);
        return deadline;
    }

    fn remainingWaitMs(deadline: ?u64) c_int {
        const until = deadline orelse return -1;
        const remaining = until -| core.monotonicNs();
        // Round up to avoid waking before the deadline; clamp to the mux limit.
        const ms = remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0);
        return @intCast(@min(ms, std.math.maxInt(c_int)));
    }

    fn waitCompleted(result: c_int, deadline: ?u64) bool {
        if (result > 0) return true;
        const until = deadline orelse return true;
        return core.monotonicNs() >= until;
    }

    fn dispatchExpiredTimers(self: *WindowsLooper) bool {
        const now = core.monotonicNs();
        var timer = self.timers.head;
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
        const side = std.meta.activeTag(arguments.pair);
        const attachment = &self.sides[@intFromEnum(side)];
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

    pub fn detach(self: *WindowsLooper, side: io.Side) helpers.DetachError!void {
        const attachment = &self.sides[@intFromEnum(side)];
        self.mutex.lock();
        const arguments = attachment.arguments orelse {
            self.mutex.unlock();
            return;
        };
        attachment.arguments = null;
        attachment.generation +%= 1;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.cleanup(),
        }
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn isAttached(self: *const WindowsLooper, side: io.Side) bool {
        return self.sides[@intFromEnum(side)].arguments != null;
    }

    pub fn resumeReading(self: *WindowsLooper, side: io.Side) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const attachment = &self.sides[@intFromEnum(side)];
        const arguments = attachment.arguments orelse return error.LooperUnavailable;
        self.mutex.lock();
        attachment.reading = true;
        self.mutex.unlock();
        switch (arguments.pair) {
            inline else => |value| value.resumeReading() catch return error.LooperUnavailable,
        }
        _ = c.pp_mux_wake(self.mux);
    }

    pub fn write(self: *WindowsLooper, packets: io.Packets, side: io.Side, destination: ?io.SocketAddress) helpers.WriteError!void {
        if (packets.len == 0) return;
        if (self.stopped) return error.LooperUnavailable;
        const attachment = &self.sides[@intFromEnum(side)];
        const arguments = attachment.arguments orelse return error.SideNotAttached;
        if (arguments.pair == .link and arguments.pair.link.native.unconnected and destination == null) return error.MissingDestination;
        for (packets) |packet| {
            const result = switch (arguments.pair) {
                inline else => |value| value.write(packet, destination),
            };
            if (result != 0) {
                if (self.on_receive) |callback| _ = callback(attachment, null, 0, null, result);
                return;
            }
        }
    }

    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        return null;
    }
};
