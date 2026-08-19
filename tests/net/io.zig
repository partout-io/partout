// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core.api;
const io = @import("source").net_io;
const c = io.c;

const mapReadResult = io.testing.mapReadResult;
const mapWriteResult = io.testing.mapWriteResult;
const reachabilityNone = io.testing.reachabilityNone;

test "maps native socket read results" {
    try std.testing.expectError(error.WouldBlock, mapReadResult(.link, c.PPIOErrorWouldBlock, false));
    try std.testing.expectEqual(@as(?usize, null), try mapReadResult(.link, 0, false));
    try std.testing.expectError(error.EndOfStream, mapReadResult(.link, 0, true));
    try std.testing.expectEqual(@as(?usize, 42), try mapReadResult(.link, 42, true));
}

test "maps native write backpressure results" {
    try std.testing.expectError(error.WouldBlock, mapWriteResult(.link, c.PPIOErrorWouldBlock, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.link, c.PPIOErrorNoBufs, false));
    try std.testing.expectError(error.LibcFailure, mapWriteResult(.link, c.PPIOErrorNoSpace, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.tun, c.PPIOErrorNoSpace, true));
    try std.testing.expectEqual(@as(usize, 7), try mapWriteResult(.link, 7, false));
}

test "constructs empty reachability" {
    const reachability = reachabilityNone();
    try std.testing.expect(!reachability.reachable);
}

test "socket wrapper reports an invalid remote address" {
    const wrapper = io.SocketWrapper{
        .socket = null,
        .options = .{
            .endpoint = .{
                .address = " \t",
                .proto = api.EndpointProtocol.init(.udp, 1194),
            },
            .timeout_ms = 0,
            .buf_size = 0,
        },
        .closes_on_empty_read = false,
    };

    try std.testing.expect(wrapper.remoteAddress() == null);
}
