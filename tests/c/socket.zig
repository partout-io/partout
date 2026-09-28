// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const io = source.net_io;

fn receiveC(socket: io.io_c.pp_socket, buf: []u8, source_address: ?*io.SocketAddress) !c_int {
    for (0..5000) |_| {
        const n = io.io_c.pp_socket_read(socket, buf.ptr, buf.len, source_address);
        if (n != io.io_c.PPIOErrorWouldBlock) return n;
        source.core.concurrency.sleepMs(1);
    }
    return error.Timeout;
}

test "C socket I/O selects addressing by socket mode" {
    inline for (.{ "127.0.0.1", "::1" }) |ip| {
        const server = io.io_c.pp_socket_open(ip, io.io_c.PPSocketProtoUDP, 0, &.{ .unconnected = true }) orelse return error.SocketFailed;
        defer io.io_c.pp_socket_free(server);
        var peer: io.SocketAddress = undefined;
        try std.testing.expect(io.io_c.pp_socket_local_address(server, &peer));
        const client = io.io_c.pp_socket_open(ip, io.io_c.PPSocketProtoUDP, peer.port, &.{ .timeout_ms = 1000 }) orelse return error.SocketFailed;
        defer io.io_c.pp_socket_free(client);
        const invalid = std.mem.zeroes(io.SocketAddress);
        // A connected socket ignores even an invalid destination.
        try std.testing.expectEqual(@as(c_int, 3), io.io_c.pp_socket_write(client, "one", 3, &invalid));
        var buf: [32]u8 = undefined;
        var sender: io.SocketAddress = undefined;
        try std.testing.expectEqual(io.io_c.PPIOErrorWouldBlock, io.io_c.pp_socket_read(client, &buf, buf.len, null));
        try std.testing.expectEqual(@as(c_int, 3), try receiveC(server, &buf, &sender));
        try std.testing.expectEqualStrings("one", buf[0..3]);
        try std.testing.expectEqual(peer.family, sender.family);
        // Unconnected writes validate the destination.
        try std.testing.expectEqual(@as(c_int, -1), io.io_c.pp_socket_write(server, "x", 1, &invalid));
        try std.testing.expectEqual(@as(c_int, 3), io.io_c.pp_socket_write(server, "two", 3, &sender));
        var source_address = peer;
        try std.testing.expectEqual(@as(c_int, 3), try receiveC(client, &buf, &source_address));
        try std.testing.expectEqualStrings("two", buf[0..3]);
        try std.testing.expectEqualDeep(invalid, source_address);
        // Source capture preserves empty datagrams and truncation checks.
        try std.testing.expectEqual(@as(c_int, 0), io.io_c.pp_socket_write(server, "", 0, &peer));
        try std.testing.expectEqual(@as(c_int, 0), try receiveC(server, &buf, &sender));
        try std.testing.expectEqual(@as(c_int, 3), io.io_c.pp_socket_write(client, "big", 3, null));
        try std.testing.expectEqual(@as(c_int, -1), try receiveC(server, buf[0..1], &sender));
        try std.testing.expectEqual(@as(c_int, 2), io.io_c.pp_socket_write(client, "ok", 2, null));
        try std.testing.expectEqual(@as(c_int, 2), try receiveC(server, &buf, &sender));
        try std.testing.expectEqualStrings("ok", buf[0..2]);
    }
}

test "C unconnected socket validates endpoints and binds both families to one port" {
    const options = io.io_c.pp_socket_open_options{ .unconnected = true };
    try std.testing.expect(io.io_c.pp_socket_open("127.0.0.1", io.io_c.PPSocketProtoTCP, 0, &options) == null);
    try std.testing.expect(io.io_c.pp_socket_open("localhost", io.io_c.PPSocketProtoUDP, 0, &options) == null);
    const v4 = io.io_c.pp_socket_open("0.0.0.0", io.io_c.PPSocketProtoUDP, 0, &options) orelse return error.SocketFailed;
    defer io.io_c.pp_socket_free(v4);
    var address: io.SocketAddress = undefined;
    try std.testing.expect(io.io_c.pp_socket_local_address(v4, &address));
    const v6 = io.io_c.pp_socket_open("::", io.io_c.PPSocketProtoUDP, address.port, &options) orelse return error.SocketFailed;
    defer io.io_c.pp_socket_free(v6);
    var address6: io.SocketAddress = undefined;
    try std.testing.expect(io.io_c.pp_socket_local_address(v6, &address6));
    try std.testing.expectEqual(address.port, address6.port);
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(io.io_c.PPIOErrorWouldBlock, io.io_c.pp_socket_read(v4, &buf, buf.len, &address));
    try std.testing.expectEqual(io.io_c.PPIOErrorWouldBlock, io.io_c.pp_socket_read(v6, &buf, buf.len, &address6));
}
