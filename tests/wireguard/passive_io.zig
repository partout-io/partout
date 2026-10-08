// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const bridge = source.wireguard_internal.passive_io;
const c = bridge.testing.abi;
const io = source.net_io;
extern "c" fn usleep(c_uint) c_int;

const Completion = struct {
    calls: usize = 0,
    count: u32 = 0,
    status: i32 = 99,
    fn finish(request: usize, count: u32, status: i32) callconv(.c) void {
        const self: *Completion = @ptrFromInt(request);
        self.calls += 1;
        self.count = count;
        self.status = status;
    }
    fn token(self: *Completion) usize {
        return @intFromPtr(self);
    }
};

const PacketIO = struct {
    reads: usize = 0,
    writes: usize = 0,
    cleanups: usize = 0,
    data_pointer: ?[*]const u8 = null,
    blocked: bool = false,
    block_write_after: ?usize = null,
    read_error: bool = false,
    write_error_after: ?usize = null,
    short_write: bool = false,

    fn read(raw: *anyopaque, buffer: []u8) io.Error!?usize {
        const self: *PacketIO = @ptrCast(@alignCast(raw));
        if (self.read_error) return error.LibcFailure;
        if (self.blocked or self.reads != 0) return error.WouldBlock;
        self.reads += 1;
        self.data_pointer = buffer.ptr;
        @memcpy(buffer[0..4], "test");
        return 4;
    }
    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *PacketIO = @ptrCast(@alignCast(raw));
        if (self.writes == self.write_error_after) return error.LibcFailure;
        if (self.short_write) return 0;
        if (self.blocked or self.writes == self.block_write_after) return error.Backpressure;
        self.writes += 1;
        self.data_pointer = data.ptr;
        return data.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *PacketIO = @ptrCast(@alignCast(raw));
        self.cleanups += 1;
    }
    fn setMask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    fn descriptor(self: *PacketIO) io.TunDescriptor {
        return .{ .fd = -1, .io = .{ .mock = .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .set_event_mask = setMask,
            .reset_events = reset,
            .last_error_code = lastError,
        } } } };
    }
};

test "WireGuard passive callbacks directly use Go buffers and wait for commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    var link: PacketIO = .{};
    var tun: PacketIO = .{};
    passive.replaceLink(link.descriptor());
    const transport = passive.transport(51820, 1400);
    var result: Completion = .{};
    var buffer: [32]u8 = undefined;
    var packets = [_]c.wg_read_packet{.{ .data = &buffer, .capacity = buffer.len }};
    var before_commit = ReadRequest{ .passive = &passive, .side = .tun, .packets = &packets, .result = &result };
    const pending = try std.Thread.spawn(.{}, ReadRequest.run, .{&before_commit});
    try waitForWaiters(&passive, 1);
    passive.replaceTun(tun.descriptor());
    pending.join();
    try std.testing.expectEqual(c.WG_IO_OK, before_commit.status);
    try std.testing.expectEqual(c.WG_IO_AGAIN, result.status);
    try std.testing.expectEqual(@as(u32, 0), result.count);
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.read.?(transport.context, &packets, 1, result.token()));
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual(@as(u32, 4), packets[0].size);
    try std.testing.expectEqual(buffer[0..].ptr, tun.data_pointer.?);
    try std.testing.expectEqualStrings("test", buffer[0..4]);
    var output = [_]c.wg_packet{.{ .data = &buffer, .size = 4 }};
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, &output, 1, result.token()));
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual(buffer[0..].ptr, tun.data_pointer.?);
    passive.quiesce();
    const calls = result.calls;
    try std.testing.expectEqual(c.WG_IO_CLOSED, transport.tun.read.?(transport.context, &packets, 1, result.token()));
    try std.testing.expectEqual(c.WG_IO_CLOSED, transport.tun.write.?(transport.context, &output, 1, result.token()));
    try std.testing.expectEqual(calls, result.calls); // Rejected requests never complete.
    passive.release();
    try std.testing.expectEqual(@as(usize, 1), link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), tun.cleanups);
}

test "WireGuard passive writes report the completed prefix under backpressure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    var link: PacketIO = .{};
    var tun: PacketIO = .{ .block_write_after = 1 };
    passive.replaceLink(link.descriptor());
    passive.replaceTun(tun.descriptor());
    const transport = passive.transport(51820, 1400);
    var result: Completion = .{};
    var packets = [_]c.wg_packet{ .{ .data = "one", .size = 3 }, .{ .data = "two", .size = 3 } };
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, &packets, 2, result.token()));
    try std.testing.expectEqual(c.WG_IO_AGAIN, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    tun.block_write_after = null;
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, packets[1..].ptr, 1, result.token()));
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(@as(usize, 2), tun.writes);
    var replacement: PacketIO = .{};
    passive.replaceLink(replacement.descriptor());
    try std.testing.expectEqual(@as(usize, 1), link.cleanups);
    try std.testing.expectEqual(@as(usize, 0), tun.cleanups);
}

test "WireGuard passive UDP preserves source and destination addresses" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const local = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.TestUnexpectedResult;
    const peer = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.TestUnexpectedResult;
    defer peer.destroy();
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    const port = (try local.localAddress()).port;
    passive.replaceLink(local.linkDescriptor());
    var destination = try peer.localAddress();
    destination.address[0..4].* = .{ 127, 0, 0, 1 };
    var endpoint: c.wg_endpoint = .{ .address = destination.address, .port = destination.port, .family = 4 };
    const transport = passive.transport(port, 1400);
    var result: Completion = .{};
    var output = [_]c.wg_packet{.{ .data = "udp", .size = 3 }};
    try std.testing.expectEqual(c.WG_IO_OK, transport.link.write.?(transport.context, &output, 1, &endpoint, result.token()));
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    var received: [32]u8 = undefined;
    var sender: io.SocketAddress = undefined;
    const size = receive: for (0..3000) |_| {
        const size = peer.receiveFrom(&received, &sender) catch |err| {
            if (err != error.WouldBlock) return err;
            _ = usleep(1000);
            continue;
        };
        break :receive size;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), size);
    try std.testing.expectEqual(port, sender.port);
    try std.testing.expectEqualStrings("udp", received[0..3]);
    try std.testing.expectEqual(@as(usize, 3), try peer.sendTo("ip!", sender));
    var input = [_]c.wg_read_packet{.{ .data = &received, .capacity = received.len }};
    for (0..3000) |_| {
        try std.testing.expectEqual(c.WG_IO_OK, transport.link.read.?(transport.context, &input, 1, result.token()));
        if (result.status != c.WG_IO_AGAIN) break;
        _ = usleep(1000);
    }
    try std.testing.expectEqual(c.WG_IO_OK, result.status);
    try std.testing.expectEqual(destination.port, input[0].source.port);
    try std.testing.expectEqual(@as(u8, 4), input[0].source.family);
    try std.testing.expectEqualStrings("ip!", received[0..3]);
}

const ReadRequest = struct {
    passive: *bridge.PassiveIO,
    side: source.net.Side,
    packets: [*c]c.wg_read_packet,
    result: *Completion,
    status: i32 = 99,
    fn run(self: *ReadRequest) void {
        const transport = self.passive.transport(51820, 1400);
        const read = if (self.side == .link) transport.link.read else transport.tun.read;
        self.status = read.?(transport.context, self.packets, 1, self.result.token());
    }
};

fn waitForWaiters(passive: *bridge.PassiveIO, count: usize) !void {
    for (0..3000) |_| {
        passive.lock.lock();
        const ready = passive.waiter.pending == count;
        passive.lock.unlock();
        if (ready) return;
        _ = usleep(1000);
    }
    passive.quiesce();
    return error.TestUnexpectedResult;
}

test "WireGuard passive shared wake cancels link and precommit TUN waits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var passive = try bridge.PassiveIO.init(Completion.finish);
    defer passive.deinit();
    const link = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.TestUnexpectedResult;
    passive.replaceLink(link.linkDescriptor());
    var buffers: [2][32]u8 = undefined;
    var packets: [2]c.wg_read_packet = undefined;
    var results: [2]Completion = .{ .{}, .{} };
    var requests: [2]ReadRequest = undefined;
    var threads: [2]std.Thread = undefined;
    for (0..2) |i| {
        packets[i] = .{ .data = &buffers[i], .capacity = 32 };
        requests[i] = .{ .passive = &passive, .side = if (i == 0) .link else .tun, .packets = &packets[i], .result = &results[i] };
        threads[i] = try std.Thread.spawn(.{}, ReadRequest.run, .{&requests[i]});
    }
    var joined = false;
    errdefer if (!joined) {
        passive.quiesce();
        for (threads) |thread| thread.join();
    };
    try waitForWaiters(&passive, 2);
    passive.quiesce();
    for (threads) |thread| thread.join();
    joined = true;
    for (results) |result| {
        try std.testing.expectEqual(@as(usize, 1), result.calls);
        try std.testing.expectEqual(c.WG_IO_CLOSED, result.status);
    }
}

const FailureRecorder = struct {
    calls: usize = 0,
    fn report(raw: *anyopaque) void {
        const self: *FailureRecorder = @ptrCast(@alignCast(raw));
        self.calls += 1;
    }
};

fn failedWait(_: c_int, _: bool, _: c_int) callconv(.c) c_int {
    return -1;
}

test "WireGuard passive terminal I/O failures report once and cancellation stays silent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Scenario = enum { read_error, write_error, short_write, wait_error, cancel };
    for (std.enums.values(Scenario)) |scenario| {
        var passive = try bridge.PassiveIO.init(Completion.finish);
        defer passive.deinit();
        var failure = FailureRecorder{};
        passive.failure = .{ .ctx = &failure, .report = FailureRecorder.report };
        var descriptor = PacketIO{
            .read_error = scenario == .read_error,
            .write_error_after = if (scenario == .write_error) 1 else null,
            .short_write = scenario == .short_write,
            .blocked = scenario == .wait_error,
        };
        passive.replaceLink(descriptor.descriptor());
        passive.replaceTun(descriptor.descriptor());
        const transport = passive.transport(51820, 1400);
        var completion = Completion{};
        var buffer: [32]u8 = undefined;
        var reads = [_]c.wg_read_packet{.{ .data = &buffer, .capacity = buffer.len }};
        const writes = [_]c.wg_packet{ .{ .data = &buffer, .size = 4 }, .{ .data = &buffer, .size = 4 } };
        if (scenario == .cancel) {
            passive.quiesce();
        } else if (scenario == .write_error or scenario == .short_write) {
            try std.testing.expectEqual(c.WG_IO_OK, transport.tun.write.?(transport.context, &writes, 2, completion.token()));
            try std.testing.expectEqual(c.WG_IO_INVALID, completion.status);
            try std.testing.expectEqual(@as(u32, if (scenario == .write_error) 1 else 0), completion.count);
        } else {
            if (scenario == .wait_error) passive.waiter.test_wait_once = failedWait;
            try std.testing.expectEqual(c.WG_IO_OK, transport.tun.read.?(transport.context, &reads, 1, completion.token()));
            try std.testing.expectEqual(c.WG_IO_INVALID, completion.status);
        }
        try std.testing.expectEqual(c.WG_IO_CLOSED, transport.tun.read.?(transport.context, &reads, 1, completion.token()));
        try std.testing.expectEqual(@as(usize, if (scenario == .cancel) 0 else 1), failure.calls);
    }
}
