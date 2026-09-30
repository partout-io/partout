// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core.api;
const io = @import("source").net_io;
const io_posix = @import("source").net_io_posix;
const io_c = io.io_c;

const mapReadResult = io_posix.mapReadResult;
const mapWriteResult = io_posix.mapWriteResult;

test "maps native socket read results" {
    try std.testing.expectError(error.WouldBlock, mapReadResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectEqual(@as(?usize, null), try mapReadResult(.link, 0, false));
    try std.testing.expectError(error.EndOfStream, mapReadResult(.link, 0, true));
    try std.testing.expectEqual(@as(?usize, 42), try mapReadResult(.link, 42, true));
}

test "maps native write backpressure results" {
    try std.testing.expectError(error.WouldBlock, mapWriteResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.link, io_c.PPIOErrorNoBufs, false));
    try std.testing.expectError(error.LibcFailure, mapWriteResult(.link, io_c.PPIOErrorNoSpace, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.tun, io_c.PPIOErrorNoSpace, true));
    try std.testing.expectEqual(@as(usize, 7), try mapWriteResult(.link, 7, false));
}

test "socket wrapper rejects an invalid remote address" {
    try std.testing.expect((try io.SocketWrapper.create(std.testing.allocator, .{ .address = " \t", .proto = api.EndpointProtocol.init(.udp, 1194) }, .{
        .timeout_ms = 0,
        .buf_size = 0,
    })) == null);
}

test "POSIX interface dispatches to owned sockets and borrowed tunnels" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    std.testing.refAllDecls(io_posix.POSIXInterface);
    const allocator = std.testing.allocator;
    const socket = try allocator.create(io_posix.SocketWrapper);
    socket.* = .{
        .allocator = allocator,
        .socket = null,
        .remote_endpoint = try io.SocketEndpoint.init(.{ .address = "127.0.0.1", .proto = .init(.udp, 1194) }),
        .closes_on_empty_read = false,
    };
    var tun = io_posix.TunWrapper.init(null);
    const native_socket = socket.linkDescriptor().io;
    defer native_socket.cleanup();
    const tun_descriptor = tun.tunDescriptor();
    const native_tun = tun_descriptor.io;
    defer tun.deinit();
    try std.testing.expect(native_tun.tun == &tun);
    try std.testing.expect(native_socket.socket == socket);
    try std.testing.expect(native_socket == .socket);
    try std.testing.expect(native_tun == .tun);
    try native_tun.setEventMask(true, true);
    try native_tun.resetEvents();
    // Invalid offsets are rejected before reaching the native handles.
    for ([_]io_posix.POSIXInterface{ native_socket, native_tun }) |native| {
        try std.testing.expectError(error.InvalidOffset, native.write("", 1));
    }
    native_tun.cleanup();
    native_tun.cleanup();
    try std.testing.expect(tun.is_closed);
}

test "socket argument errors are rejected before native I/O" {
    const endpoint = try io.SocketEndpoint.init(.{ .address = "127.0.0.1", .proto = .init(.udp, 1194) });
    var socket = io_posix.SocketWrapper{
        .allocator = std.testing.allocator,
        .socket = null,
        .remote_endpoint = endpoint,
    };
    const native = io_posix.POSIXInterface{ .socket = &socket };
    var buf: [8]u8 = undefined;
    var address: io.SocketAddress = undefined;

    try std.testing.expectError(error.InvalidSocketMode, socket.receiveFrom(&buf, &address));
    try std.testing.expectError(error.InvalidSocketMode, socket.sendTo("payload", endpoint.address));
    try std.testing.expectError(error.InvalidOffset, native.write("payload", 8));

    socket.remote_endpoint = null;
    try std.testing.expectError(error.InvalidSocketMode, native.read(&buf));
    try std.testing.expectError(error.InvalidSocketMode, native.write("payload", 0));
    try std.testing.expectError(error.MissingDestination, native.writePacket("payload", 0, null));
    for ([_]u8{ 0, 5, 255 }) |family| {
        var invalid_address = endpoint.address;
        invalid_address.family = family;
        try std.testing.expectError(error.InvalidAddressFamily, socket.sendTo("payload", invalid_address));
        try std.testing.expectError(error.InvalidAddressFamily, native.writePacket("payload", 0, invalid_address));
    }

    // Valid arguments reach the invalid native handle and retain its native error.
    try std.testing.expectError(error.LibcFailure, socket.sendTo("payload", endpoint.address));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.E.BADF)), native.lastErrorCode());
}
