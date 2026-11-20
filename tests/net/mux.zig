// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");
const ffi = source.ffi;
const io_c = ffi.io;

test "mux wait observes explicit wake" {
    const mux = io_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer io_c.pp_mux_free(mux);

    // Queue the wake first so the test is deterministic without thread timing.
    try std.testing.expect(io_c.pp_mux_wake(mux));
    try std.testing.expectEqual(@as(c_int, 1), io_c.pp_mux_wait(mux, -1, null));
}

test "mux wait preserves the null-mux error" {
    try std.testing.expectEqual(
        io_c.PPMuxErrorNull,
        io_c.pp_mux_wait(null, -1, null),
    );
}

test "mux wait supports polling and timer timeouts" {
    const mux = io_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer io_c.pp_mux_free(mux);
    var code: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), io_c.pp_mux_wait(mux, 0, &code));
    try std.testing.expectEqual(@as(c_int, 0), io_c.pp_mux_wait(mux, 2, &code));
    try std.testing.expectEqual(@as(c_int, 0), code);
    try std.testing.expect(io_c.pp_mux_wake(mux));
    try std.testing.expectEqual(@as(c_int, 1), io_c.pp_mux_wait(mux, 1000, &code));
    try std.testing.expectEqual(@as(c_int, 0), io_c.pp_mux_wait(mux, 0, &code));
}

test "Wintun socket hooks consume readiness and restore paused reads" {
    if (!source.wintun_enabled) return error.SkipZigTest;
    const server = io_c.pp_socket_open("127.0.0.1", io_c.PPSocketProtoUDP, 0, &.{ .unconnected = true }) orelse return error.SocketFailed;
    defer io_c.pp_socket_free(server);
    var server_address: io_c.pp_socket_address = undefined;
    try std.testing.expect(io_c.pp_socket_get_address(server, &server_address));
    const client = io_c.pp_socket_open("127.0.0.1", io_c.PPSocketProtoUDP, server_address.port, &.{ .timeout_ms = 1000 }) orelse return error.SocketFailed;
    defer io_c.pp_socket_free(client);
    var client_address: io_c.pp_socket_address = undefined;
    try std.testing.expect(io_c.pp_socket_get_address(client, &client_address));
    // A separate manual-reset event models the TUN's read-wait handle.
    const tun = io_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer io_c.pp_mux_free(tun);
    const mux = io_c.pp_mux_create(2) orelse return error.MuxCreationFailed;
    defer io_c.pp_mux_free(mux);
    const fd = io_c.pp_socket_get_watch_fd(client);
    try std.testing.expect(io_c.pp_mux_add(mux, fd));
    try std.testing.expect(io_c.pp_mux_add(mux, io_c.pp_mux_wake_descriptor(tun)));
    const Probe = struct {
        socket: io_c.pp_socket,
        tun: io_c.pp_mux,
        reads: usize = 0,
        writes: usize = 0,
        tun_reads: usize = 0,
        failed: bool = false,

        fn read(raw: ?*anyopaque, ready_fd: io_c.pp_fd) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (ready_fd == io_c.pp_mux_wake_descriptor(self.tun)) {
                self.tun_reads += 1;
                _ = io_c.pp_mux_reset_wake(self.tun);
                return;
            }
            if (!io_c.pp_socket_reset_events(self.socket)) self.failed = true;
            var byte: [1]u8 = undefined;
            if (io_c.pp_socket_read(self.socket, &byte, 1, null) != 1 or byte[0] != 'x') self.failed = true;
            self.reads += 1;
        }

        fn write(raw: ?*anyopaque, _: io_c.pp_fd) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!io_c.pp_socket_reset_events(self.socket)) self.failed = true;
            self.writes += 1;
        }
    };
    var probe: Probe = .{ .socket = client, .tun = tun };
    io_c.pp_mux_set_on_readable(mux, Probe.read, &probe);
    io_c.pp_mux_set_on_writable(mux, Probe.write, &probe);
    try std.testing.expect(io_c.pp_socket_set_event_mask(client, false, true));
    try std.testing.expect(io_c.pp_mux_set_read(mux, fd, false));
    try std.testing.expect(io_c.pp_mux_set_write(mux, fd, true));
    try std.testing.expect(io_c.pp_mux_wake(tun));
    for (0..4) |_| {
        _ = io_c.pp_mux_wait(mux, 100, null);
        if (probe.writes == 1 and probe.tun_reads == 1) break;
    }
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqual(@as(usize, 1), probe.tun_reads);
    try std.testing.expectEqual(@as(usize, 0), probe.reads);
    try std.testing.expect(io_c.pp_mux_set_write(mux, fd, false));
    try std.testing.expect(io_c.pp_mux_set_read(mux, fd, true));
    try std.testing.expect(io_c.pp_socket_set_event_mask(client, true, false));
    for (0..2) |_| {
        try std.testing.expectEqual(@as(c_int, 1), io_c.pp_socket_write(server, "x", 1, &client_address));
        try std.testing.expect(io_c.pp_mux_wait(mux, 1000, null) > 0);
        try std.testing.expectEqual(@as(c_int, 0), io_c.pp_mux_wait(mux, 0, null));
    }
    try std.testing.expectEqual(@as(usize, 2), probe.reads);
    try std.testing.expect(!probe.failed);
    // A paused socket must not wake the loop, and resume must expose queued input.
    try std.testing.expect(io_c.pp_mux_set_read(mux, fd, false));
    try std.testing.expect(io_c.pp_socket_set_event_mask(client, false, false));
    try std.testing.expectEqual(@as(c_int, 1), io_c.pp_socket_write(server, "x", 1, &client_address));
    try std.testing.expectEqual(@as(c_int, 0), io_c.pp_mux_wait(mux, 0, null));
    try std.testing.expect(io_c.pp_mux_set_read(mux, fd, true));
    try std.testing.expect(io_c.pp_socket_set_event_mask(client, true, false));
    try std.testing.expect(io_c.pp_mux_wait(mux, 1000, null) > 0);
    try std.testing.expectEqual(@as(usize, 3), probe.reads);
    try std.testing.expect(!probe.failed);
}
