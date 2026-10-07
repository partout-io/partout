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

    fn read(raw: *anyopaque, buffer: []u8) io.Error!?usize {
        const self: *PacketIO = @ptrCast(@alignCast(raw));
        if (self.blocked or self.reads != 0) return error.WouldBlock;
        self.reads += 1;
        self.data_pointer = buffer.ptr;
        @memcpy(buffer[0..4], "test");
        return 4;
    }
    fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        const self: *PacketIO = @ptrCast(@alignCast(raw));
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
    var passive: bridge.PassiveIO = .{ .complete = Completion.finish };
    defer passive.release();
    var link: PacketIO = .{};
    var tun: PacketIO = .{};
    passive.replaceLink(link.descriptor());
    const transport = passive.transport(51820, 1400);
    var result: Completion = .{};
    var buffer: [32]u8 = undefined;
    var packets = [_]c.wg_read_packet{.{ .data = &buffer, .capacity = buffer.len }};
    try std.testing.expectEqual(c.WG_IO_OK, transport.tun.read.?(transport.context, &packets, 1, result.token()));
    try std.testing.expectEqual(c.WG_IO_AGAIN, result.status);
    try std.testing.expectEqual(@as(u32, 0), result.count);
    passive.replaceTun(tun.descriptor());
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
    var passive: bridge.PassiveIO = .{ .complete = Completion.finish };
    defer passive.release();
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
    var passive: bridge.PassiveIO = .{ .complete = Completion.finish };
    defer passive.release();
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
