// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");
const ffi = source.ffi;

const io_c = ffi.io;

/// Standalone looper tests supply the mailbox that production gets from Daemon.
pub const Mailbox = struct {
    looper: *source.net_looper.Looper,
    mutex: source.core.Mutex = .{},
    inputs: source.core.Fifo(Node) = .{},
    closed: bool = false,

    const Node = struct {
        input: source.net_looper.Looper.PacketSubmission,
        next: ?*Node = null,

        fn ready(self: *const Node, mailbox: *Mailbox) bool {
            return mailbox.looper.impl.canDeliverPackets(self.input);
        }
    };

    pub fn bind(self: *Mailbox) void {
        if (builtin.os.tag == .windows) {
            self.looper.impl.on_receive = receive;
            self.looper.impl.receive_context = self;
        }
    }

    pub fn deinit(self: *Mailbox) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        self.looper.stop() catch unreachable;
        while (self.inputs.take()) |node| self.free(node);
        self.mutex.deinit();
    }

    fn post(raw: *anyopaque, input: source.net_looper.Looper.PacketSubmission) error{ Closed, OutOfMemory }!void {
        const self: *Mailbox = @ptrCast(@alignCast(raw));
        const node = try self.looper.allocator.create(Node);
        errdefer self.looper.allocator.destroy(node);
        node.* = .{ .input = input };
        node.input.bytes = try self.looper.allocator.dupe(u8, input.bytes);
        errdefer self.looper.allocator.free(node.input.bytes);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        self.inputs.append(node);
        _ = io_c.pp_mux_wake(self.looper.impl.mux);
    }

    fn receive(raw: ?*anyopaque, bytes: [*c]const u8, length: usize, address: [*c]const source.net_io.SocketAddress, code: i32) callconv(.c) bool {
        const attachment: *source.net_looper.Looper.Impl.Attachment = @ptrCast(@alignCast(raw.?));
        const input = attachment.input(bytes, length, address, code) orelse return false;
        const self: *Mailbox = @ptrCast(@alignCast(attachment.owner.receive_context.?));
        post(self, input) catch return false;
        return attachment.keepReading(input);
    }

    fn free(self: *Mailbox, node: *Node) void {
        self.looper.allocator.free(node.input.bytes);
        self.looper.allocator.destroy(node);
    }

    fn poll(self: *Mailbox, max_wait_ms: ?u32) !bool {
        self.mutex.lock();
        var queued = false;
        var pending = self.inputs.head;
        while (pending) |node| : (pending = node.next) queued = queued or self.looper.impl.canDeliverPackets(node.input);
        self.mutex.unlock();
        var failure: ?source.net_io.Failure = null;
        const alive = self.looper.impl.loopOnce(if (queued) 0 else max_wait_ms, &failure);
        try std.testing.expect(failure == null);
        if (!alive) return false;
        for (0..self.looper.impl.max_read_count) |_| {
            self.mutex.lock();
            const node = self.inputs.removeWhere(self, Node.ready);
            self.mutex.unlock();
            const input = node orelse break;
            self.looper.impl.deliverPackets(input.input);
            self.free(input);
        }
        return !self.looper.impl.stopped;
    }
};

/// Each test owns the mux until after its looper is destroyed.
pub const Mux = struct {
    handle: io_c.pp_mux,

    pub fn init() !Mux {
        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
        return .{ .handle = io_c.pp_mux_create(2) orelse return error.MuxCreationFailed };
    }

    pub fn deinit(self: Mux) void {
        io_c.pp_mux_free(self.handle);
    }

    pub fn signal(self: Mux) void {
        std.debug.assert(io_c.pp_mux_wake(self.handle));
    }

    pub fn reset(self: Mux) !void {
        try std.testing.expect(io_c.pp_mux_reset_wake(self.handle));
    }
};

/// Bound waits while advancing I/O synchronously on the test thread.
pub fn wait(loop: anytype, value: anytype, expected: usize) !void {
    for (0..500) |_| {
        if (value.load(.acquire) >= expected) return;
        if (!try poll(loop, 10)) return error.LooperStopped;
    }
    return error.Timeout;
}

/// Preserve bounded polling while checking the explicit failure outcome.
pub fn poll(loop: anytype, max_wait_ms: ?u32) !bool {
    var failure: ?source.net_io.Failure = null;
    const owner = if (@typeInfo(@TypeOf(loop.*)) == .pointer) loop.* else loop;
    const impl = if (@hasField(@TypeOf(owner.*), "impl")) owner.impl else owner;
    if (comptime builtin.os.tag == .windows and @hasField(@TypeOf(impl.*), "on_receive")) {
        if (impl.on_receive) |callback| {
            if (callback == Mailbox.receive) {
                const mailbox: *Mailbox = @ptrCast(@alignCast(impl.receive_context.?));
                return mailbox.poll(max_wait_ms);
            }
        }
    }
    const alive = impl.loopOnce(max_wait_ms, &failure);
    try std.testing.expect(failure == null);
    return alive;
}
