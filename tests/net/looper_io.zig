// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const io = source.net_io;
const Looper = source.net_looper_v2.Looper;
const queues = source.net_looper_helpers;
const allocator = std.testing.allocator;
const Atomic = std.atomic.Value(usize);
const libc = struct {
    extern "c" fn usleep(c_uint) c_int;
    extern "c" fn close(std.c.fd_t) c_int;
};

fn finish(_: ?*anyopaque, _: ?Looper.Failure) void {}
fn barrier(_: ?*anyopaque) anyerror!void {}

const CompletionProbe = struct {
    looper: ?*Looper = null,
    calls: Atomic = .init(0),
    result: Looper.IOResult = .{},
    on_queue: bool = false,

    fn completed(raw: ?*anyopaque, result: Looper.IOResult) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(raw.?));
        self.result = result;
        // Also verifies that the callback does not hold the looper mutex.
        if (self.looper) |looper| self.on_queue = looper.isOnQueue();
        _ = self.calls.fetchAdd(1, .release);
    }

    fn callback(self: *CompletionProbe) Looper.OnIOComplete {
        return .{ .context = self, .callback = completed };
    }

    fn wait(self: *CompletionProbe) !void {
        for (0..5000) |_| {
            if (self.calls.load(.acquire) != 0) return;
            _ = libc.usleep(1000);
        }
        return error.Timeout;
    }
};

const ReadProbe = struct {
    buffers: []Looper.ReadBuffer,
    loop: *Looper,
    acquired: usize = 0,
    delivered: usize = 0,
    released: Atomic = .init(0),
    result: Looper.IOResult = .{},
    pause: bool = false,
    empty: bool = false,
    fail_callback: bool = false,
    on_queue: bool = true,
    lifecycle_rejected: bool = false,

    fn acquire(raw: ?*anyopaque) []Looper.ReadBuffer {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.acquired += 1;
        self.on_queue = self.on_queue and self.loop.isOnQueue();
        return if (self.empty) &.{} else self.buffers;
    }

    fn read(raw: ?*anyopaque, packets: Looper.Packets, addresses: ?[]const io.SocketAddress) anyerror!Looper.ReadAction {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.on_queue = self.on_queue and self.loop.isOnQueue();
        // Read data reaches the original callback without a payload copy.
        for (packets, 0..) |packet, i| {
            try std.testing.expect(packet.ptr == self.buffers[i].data.ptr);
            try std.testing.expectEqual(self.buffers[i].size, packet.len);
            if (addresses) |sources| try std.testing.expectEqualDeep(self.buffers[i].source.?, sources[i]);
        }
        self.loop.detach(.tun) catch |err| {
            self.lifecycle_rejected = err == error.ReentrantCall;
        };
        self.delivered += 1;
        if (self.fail_callback) return error.ReadCallbackFailed;
        return if (self.pause) .pause else .keep;
    }

    fn release(raw: ?*anyopaque, _: []Looper.ReadBuffer, result: Looper.IOResult) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.on_queue = self.on_queue and self.loop.isOnQueue();
        self.result = result;
        _ = self.released.fetchAdd(1, .release);
    }

    fn attach(self: *@This(), pair: Looper.DescriptorPair) Looper.AttachArguments {
        return .{
            .pair = pair,
            .on_read = .{ .context = self, .callback = read },
            .read_buffers = .{ .context = self, .acquire = acquire, .release = release },
        };
    }

    fn wait(self: *@This(), count: usize) !void {
        for (0..5000) |_| {
            if (self.released.load(.acquire) >= count) return;
            _ = libc.usleep(1000);
        }
        return error.Timeout;
    }
};

const Mock = struct {
    fd: std.c.fd_t,
    expected_read: ?[*]u8 = null,
    expected_write: ?[*]const u8 = null,
    read_matched: bool = false,
    write_matched: bool = false,
    block_writes: bool = false,
    backpressure_once: bool = false,
    fail_read: bool = false,
    fail_read_after: ?usize = null,
    reads: usize = 0,
    partial_once: bool = false,
    fail_after: ?usize = null,
    writes: usize = 0,
    cleaned: usize = 0,

    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(raw: *anyopaque, data: []u8) io.Error!?usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.fail_read) return error.LibcFailure;
        if (self.fail_read_after) |count| if (self.reads >= count) return error.LibcFailure;
        var byte: [1]u8 = undefined;
        if (std.c.read(self.fd, &byte, 1) != 1) return error.WouldBlock;
        self.reads += 1;
        self.read_matched = data.ptr == self.expected_read;
        data[0] = byte[0];
        return 1;
    }
    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *Mock = @ptrCast(@alignCast(raw));
        if (self.block_writes) return error.WouldBlock;
        if (self.fail_after) |limit| if (self.writes >= limit) return error.LibcFailure;
        if (self.backpressure_once) {
            self.backpressure_once = false;
            return error.Backpressure;
        }
        if (self.expected_write) |expected| self.write_matched = data.ptr == expected;
        if (self.partial_once) {
            self.partial_once = false;
            return 1;
        }
        self.writes += 1;
        return data.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(raw));
        self.cleaned += 1;
    }
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    const vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
        .set_event_mask = mask,
        .reset_events = reset,
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastError,
    };

    fn pair(self: *Mock) Looper.DescriptorPair {
        return .{ .tun = .{ .fd = self.fd, .io = .{ .mock = .{ .ptr = self, .vtable = &vtable } } } };
    }
};

fn pipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    errdefer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    const flags = std.c.fcntl(fds[0], std.c.F.GETFL, @as(c_int, 0));
    if (std.c.fcntl(fds[0], std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0) return error.FcntlFailed;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    _ = libc.close(fds[0]);
    _ = libc.close(fds[1]);
}

test "v2 spontaneous reads reuse caller storage without submissions or allocations" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    var bytes: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    var buffers = [_]Looper.ReadBuffer{ .{ .data = &bytes }, .{ .data = &second, .size = 99 } };
    var mock = Mock{ .fd = fds[0], .expected_read = &bytes };
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var loop = try Looper.init(failing.allocator(), .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    var read = ReadProbe{ .loop = &loop, .buffers = &buffers };
    try loop.start();
    try loop.attach(read.attach(mock.pair()));
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try read.wait(1);
    try std.testing.expectEqual(@as(u8, 'x'), bytes[0]);
    // No rearming: the next arrival produces another on_read callback.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "y", 1));
    try read.wait(2);
    try loop.stop();
    try std.testing.expect(mock.read_matched);
    try std.testing.expect(read.on_queue);
    try std.testing.expect(read.lifecycle_rejected);
    try std.testing.expectEqual(@as(usize, 2), read.delivered);
    try std.testing.expectEqual(read.acquired, read.released.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), read.result.count);
    try std.testing.expect(read.result.failure == null);
    try std.testing.expectEqual(@as(u8, 'y'), bytes[0]);
    try std.testing.expect(buffers[0].source == null);
    try std.testing.expectEqual(@as(usize, 99), buffers[1].size);
}

test "v2 borrowed writes preserve payload identity across partial writes and backpressure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipe();
    defer closePipe(fds);
    const payload = "borrowed";
    var mock = Mock{ .fd = fds[0], .expected_write = payload.ptr, .partial_once = true, .backpressure_once = true };
    var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    try loop.attach(.{ .pair = mock.pair() });
    var completion = CompletionProbe{ .looper = &loop };
    try loop.writeQueued(&.{payload}, .tun, null, completion.callback());
    try completion.wait();
    try std.testing.expect(completion.on_queue);
    try std.testing.expect(mock.write_matched);
    try std.testing.expectEqual(@as(usize, 1), mock.writes);
    try std.testing.expectEqual(@as(usize, 1), completion.result.count);
    try std.testing.expect(completion.result.failure == null);
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 1), completion.calls.load(.acquire));
}

test "v2 detach stop and deinit cancel pending writes without acquiring idle read buffers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Action = enum { detach, stop, deinit };
    inline for (.{ Action.detach, Action.stop, Action.deinit }) |action| {
        const fds = try pipe();
        defer closePipe(fds);
        var mock = Mock{ .fd = fds[0], .block_writes = true };
        var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
        var destroyed = false;
        defer if (!destroyed) loop.deinit();
        try loop.start();
        var bytes: [16]u8 = undefined;
        var buffers = [_]Looper.ReadBuffer{.{ .data = &bytes }};
        var read = ReadProbe{ .loop = &loop, .buffers = &buffers };
        var write = CompletionProbe{ .looper = &loop };
        try loop.attach(read.attach(mock.pair()));
        try loop.writeQueued(&.{"pending"}, .tun, null, write.callback());
        switch (action) {
            .detach => try loop.detach(.tun),
            .stop => try loop.stop(),
            .deinit => {
                loop.deinit();
                destroyed = true;
            },
        }
        try std.testing.expectEqual(@as(usize, 0), read.acquired);
        try std.testing.expectEqual(@as(usize, 1), write.calls.load(.acquire));
        try std.testing.expect(write.on_queue);
        try std.testing.expect(write.result.failure.? == error.Cancelled);
        try std.testing.expectEqual(@as(usize, 0), read.result.count);
        try std.testing.expectEqual(@as(usize, 0), write.result.count);
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
    }
}

test "v2 read failures and callback failures release buffers before detaching" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Failure = enum { io, partial, callback, invalid_buffer };
    for (std.enums.values(Failure)) |failure| {
        const fds = try pipe();
        defer closePipe(fds);
        var mock = Mock{ .fd = fds[0], .fail_read = failure == .io, .fail_read_after = if (failure == .partial) 1 else null };
        var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
        defer loop.deinit();
        var bytes: [16]u8 = undefined;
        var other: [16]u8 = undefined;
        var buffers = [_]Looper.ReadBuffer{ .{ .data = if (failure == .invalid_buffer) &.{} else &bytes }, .{ .data = &other } };
        var read = ReadProbe{ .loop = &loop, .buffers = &buffers, .fail_callback = failure == .callback };
        try loop.start();
        try loop.attach(read.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
        try read.wait(1);
        try loop.performTask(.{ .callback = barrier });
        try std.testing.expect(!loop.isTunAttached());
        try loop.stop();
        try std.testing.expectEqual(@as(usize, 1), read.acquired);
        try std.testing.expectEqual(@as(usize, 1), read.released.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
        try std.testing.expectEqual(@as(usize, if (failure == .partial or failure == .callback) 1 else 0), read.result.count);
        try std.testing.expectEqual(@as(usize, if (failure == .partial or failure == .callback) 1 else 0), read.delivered);
        switch (failure) {
            .io, .partial => try std.testing.expect(read.result.failure.? == error.LibcFailure),
            .invalid_buffer => try std.testing.expect(read.result.failure.? == error.InvalidBuffers),
            .callback => try std.testing.expect(read.result.failure == null),
        }
    }
}

test "v2 rejected requests and Windows stubs do not invoke completions" {
    var completion = CompletionProbe{};
    var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try std.testing.expectError(error.LooperUnavailable, loop.writeQueued(&.{"x"}, .tun, null, completion.callback()));
    try loop.start();
    if (builtin.os.tag == .windows) {
        // Instantiate the additional ABI even before native Windows I/O exists.
        var tun = io.TunWrapper{};
        try std.testing.expectError(error.LooperUnavailable, loop.attach(.{ .pair = .{ .tun = tun.tunDescriptor() } }));
    } else {
        try std.testing.expectError(error.SideNotAttached, loop.writeQueued(&.{"x"}, .tun, null, completion.callback()));
        try std.testing.expectError(error.InvalidBuffers, loop.writeQueued(&.{}, .tun, null, completion.callback()));
        const fds = try pipe();
        defer closePipe(fds);
        var mock = Mock{ .fd = fds[0] };
        try std.testing.expectError(error.InvalidBuffers, loop.attach(.{
            .pair = mock.pair(),
            .on_read = .{ .callback = ReadProbe.read },
        }));
        try std.testing.expect(!loop.isTunAttached());
        try loop.attach(.{ .pair = mock.pair() });
        try loop.detach(.tun);
    }
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 0), completion.calls.load(.acquire));
}

test "v2 write requests retain borrowed slices and report partial progress" {
    var queue = source.core.Fifo(queues.WriteRequest){};
    defer while (queue.take()) |request| request.complete(allocator, error.Cancelled);
    var completion = CompletionProbe{};
    const first = [_]u8{1};
    var first_completion = CompletionProbe{};
    const payload = "borrowed";
    var packets = [_]Looper.Packet{ payload, "" };
    var address = std.mem.zeroes(io.SocketAddress);
    address.port = 123;
    const first_request = try allocator.create(queues.WriteRequest);
    first_request.* = .{ .packets = &.{&first}, .destination = null, .completion = first_completion.callback() };
    queue.append(first_request);
    const request = try allocator.create(queues.WriteRequest);
    request.* = .{ .packets = &packets, .destination = address, .completion = completion.callback() };
    queue.append(request);
    address.port = 456;
    try std.testing.expect(first_request.advance(1));
    queue.take().?.complete(allocator, null);
    try std.testing.expectEqual(@as(usize, 1), first_completion.calls.load(.acquire));
    try std.testing.expect(queue.head.?.packets.ptr == &packets);
    try std.testing.expect(request.pending().data.ptr == payload.ptr);
    try std.testing.expectEqual(@as(u16, 123), request.pending().address.?.port);
    try std.testing.expect(!request.advance(1));
    try std.testing.expectEqual(@as(usize, 1), request.pending().offset);
    try std.testing.expect(!request.advance(payload.len - 1));
    queue.take().?.complete(allocator, error.Cancelled);
    try std.testing.expectEqual(@as(usize, 1), completion.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), completion.result.count);
    try std.testing.expect(completion.result.failure.? == error.Cancelled);
}

test "v2 rejected I/O allocations release commands without invoking completion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (0..2) |successful_allocations| {
        const fds = try pipe();
        defer closePipe(fds);
        var mock = Mock{ .fd = fds[0] };
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var loop = try Looper.init(failing.allocator(), .{ .on_finish = .{ .callback = finish } });
        defer loop.deinit();
        try loop.start();
        try loop.attach(.{ .pair = mock.pair() });
        var completion = CompletionProbe{};
        failing.fail_index = failing.alloc_index + successful_allocations;
        try std.testing.expectError(error.OutOfMemory, loop.writeQueued(&.{"borrowed"}, .tun, null, completion.callback()));
        failing.fail_index = std.math.maxInt(usize);
        try loop.stop();
        try std.testing.expectEqual(@as(usize, 0), completion.calls.load(.acquire));
    }
}

fn destination(socket: *io.SocketWrapper, family: u8) !io.SocketAddress {
    var address = std.mem.zeroes(io.SocketAddress);
    address.family = family;
    address.port = (try socket.localAddress()).port;
    if (family == 4) {
        address.address[0] = 127;
        address.address[3] = 1;
    } else address.address[15] = 1;
    return address;
}

fn receive(socket: *io.SocketWrapper, bytes: []u8) !usize {
    var address: io.SocketAddress = undefined;
    for (0..5000) |_| {
        return socket.receiveFrom(bytes, &address) catch |err| {
            if (err != error.WouldBlock) return err;
            _ = libc.usleep(1000);
            continue;
        };
    }
    return error.Timeout;
}

test "v2 borrowed UDP batches retain sources and empty datagrams" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    const socket = (try io.SocketWrapper.create(allocator, null, .{})) orelse return error.SocketFailed;
    const v4 = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer v4.destroy();
    const v6 = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = false })) orelse return error.SocketFailed;
    defer v6.destroy();
    _ = try v4.sendTo("one", try destination(socket, 4));
    _ = try v6.sendTo("", try destination(socket, 6));
    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    var buffers = [_]Looper.ReadBuffer{ .{ .data = &first }, .{ .data = &second } };
    var read = ReadProbe{ .loop = &loop, .buffers = &buffers, .pause = true };
    loop.attach(read.attach(.{ .link = socket.linkDescriptor() })) catch |err| {
        socket.destroy();
        return err;
    };
    try read.wait(1);
    try std.testing.expectEqual(@as(usize, 2), read.result.count);
    try std.testing.expect(read.result.failure == null);
    var writes = [_]CompletionProbe{ .{ .looper = &loop }, .{ .looper = &loop } };
    var packets: [2][1]Looper.Packet = undefined;
    for (buffers, &writes, &packets) |buffer, *write, *packet| {
        const address = buffer.source.?;
        if (address.family == 4) {
            try std.testing.expectEqualStrings("one", buffer.data[0..buffer.size]);
            try std.testing.expectEqual((try v4.localAddress()).port, address.port);
        } else {
            try std.testing.expectEqual(@as(u8, 6), address.family);
            try std.testing.expectEqual(@as(usize, 0), buffer.size);
            try std.testing.expectEqual((try v6.localAddress()).port, address.port);
        }
        packet[0] = buffer.data[0..buffer.size];
        try loop.writeQueued(packet, .link, address, write.callback());
    }
    for (&writes) |*write| {
        try write.wait();
        try std.testing.expectEqual(@as(usize, 1), write.result.count);
        try std.testing.expect(write.result.failure == null);
    }
    var reply: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try receive(v4, &reply));
    try std.testing.expectEqualStrings("one", reply[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try receive(v6, &reply));
    var rejected = CompletionProbe{};
    try std.testing.expectError(error.MissingDestination, loop.writeQueued(&.{"x"}, .link, null, rejected.callback()));
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 0), rejected.calls.load(.acquire));
}

test "v2 read callbacks and empty providers pause until resumed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |empty| {
        const fds = try pipe();
        defer closePipe(fds);
        var bytes: [16]u8 = undefined;
        var buffers = [_]Looper.ReadBuffer{.{ .data = &bytes }};
        var mock = Mock{ .fd = fds[0], .expected_read = &bytes };
        var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
        defer loop.deinit();
        var read = ReadProbe{ .loop = &loop, .buffers = &buffers, .pause = true, .empty = empty };
        try loop.start();
        try loop.attach(read.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "xy", 2));
        try read.wait(1);
        try loop.performTask(.{ .callback = barrier });
        try std.testing.expectEqual(@as(usize, 1), read.acquired);
        try std.testing.expectEqual(@as(usize, if (empty) 0 else 1), read.delivered);
        read.empty = false;
        try loop.resumeReading(.tun);
        try read.wait(2);
        try loop.stop();
        try std.testing.expectEqual(@as(usize, 2), read.acquired);
        try std.testing.expectEqual(@as(u8, if (empty) 'x' else 'y'), bytes[0]);
    }
}

test "v2 write failure reports the completed prefix and cancels later requests" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Submission = struct {
        loop: *Looper,
        first: *CompletionProbe,
        second: *CompletionProbe,

        fn submit(raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.loop.writeQueued(&.{ "one", "two" }, .tun, null, self.first.callback());
            try self.loop.writeQueued(&.{"later"}, .tun, null, self.second.callback());
        }
    };
    const fds = try pipe();
    defer closePipe(fds);
    var mock = Mock{ .fd = fds[0], .fail_after = 1 };
    var loop = try Looper.init(allocator, .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    try loop.attach(.{ .pair = mock.pair() });
    var first = CompletionProbe{ .looper = &loop };
    var second = CompletionProbe{ .looper = &loop };
    var submission = Submission{ .loop = &loop, .first = &first, .second = &second };
    try loop.performTask(.{ .context = &submission, .callback = Submission.submit });
    try first.wait();
    try second.wait();
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 1), first.result.count);
    try std.testing.expect(first.result.failure.? == error.LibcFailure);
    try std.testing.expectEqual(@as(usize, 0), second.result.count);
    try std.testing.expect(second.result.failure.? == error.Cancelled);
    try std.testing.expectEqual(@as(usize, 1), first.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), second.calls.load(.acquire));
}

test "v2 spontaneous reads honor packet and byte limits without rearming" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |limit_bytes| {
        const fds = try pipe();
        defer closePipe(fds);
        var first: [16]u8 = undefined;
        var second: [16]u8 = undefined;
        var buffers = [_]Looper.ReadBuffer{ .{ .data = &first }, .{ .data = &second } };
        var mock = Mock{ .fd = fds[0], .expected_read = &first };
        var loop = try Looper.init(allocator, .{
            .on_finish = .{ .callback = finish },
            .max_read_count = if (limit_bytes) 2 else 1,
            .max_read_size = if (limit_bytes) 1 else 1024,
        });
        defer loop.deinit();
        var read = ReadProbe{ .loop = &loop, .buffers = &buffers };
        try loop.start();
        try loop.attach(read.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "xy", 2));
        try read.wait(2);
        try loop.stop();
        try std.testing.expectEqual(@as(usize, 2), read.delivered);
        try std.testing.expectEqual(@as(usize, 1), read.result.count);
        try std.testing.expectEqual(@as(u8, 'y'), first[0]);
    }
}

test "v2 read attachment allocation failures return descriptor ownership" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (0..2) |successful_allocations| {
        const fds = try pipe();
        defer closePipe(fds);
        var mock = Mock{ .fd = fds[0] };
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var loop = try Looper.init(failing.allocator(), .{ .on_finish = .{ .callback = finish } });
        defer loop.deinit();
        var bytes: [16]u8 = undefined;
        var buffers = [_]Looper.ReadBuffer{.{ .data = &bytes }};
        var read = ReadProbe{ .loop = &loop, .buffers = &buffers, .pause = true };
        try loop.start();
        failing.fail_index = failing.alloc_index + successful_allocations;
        try std.testing.expectError(error.OutOfMemory, loop.attach(read.attach(mock.pair())));
        try std.testing.expect(!loop.isTunAttached());
        try std.testing.expectEqual(@as(usize, 0), mock.cleaned);
        try std.testing.expectEqual(@as(usize, 0), read.acquired);
        failing.fail_index = std.math.maxInt(usize);
        try loop.attach(read.attach(mock.pair()));
        try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
        try read.wait(1);
        try loop.stop();
        try std.testing.expectEqual(@as(usize, 1), mock.cleaned);
    }
}
