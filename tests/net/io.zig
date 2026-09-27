// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const io = @import("source").net_io;

const reachabilityNone = io.testing.reachabilityNone;

test "constructs empty reachability" {
    const reachability = reachabilityNone();
    try std.testing.expect(!reachability.reachable);
}

test "resolved endpoints become socket addresses with host-order ports and IPv6 scopes" {
    const v4 = try io.socketAddress(.{ .address = "192.0.2.1", .proto = .init(.udp, 1194) });
    try std.testing.expectEqual(@as(u8, 4), v4.family);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1 }, v4.address[0..4]);
    try std.testing.expectEqual(@as(u16, 1194), v4.port);
    const v6 = try io.socketAddress(.{ .address = "fe80::1%12", .proto = .init(.udp, 51820) });
    try std.testing.expectEqual(@as(u8, 6), v6.family);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &v6.address);
    try std.testing.expectEqual(@as(u32, 12), v6.scope_id);
    try std.testing.expectEqual(@as(u16, 51820), v6.port);
    const unscoped = try io.socketAddress(.{ .address = "::1", .proto = .init(.tcp, 443) });
    try std.testing.expectEqual(@as(u32, 0), unscoped.scope_id);
    for ([_][]const u8{ "vpn.example.com", "fe80::1%bad", "fe80::1%", "127.0.0.1%0" }) |invalid| {
        try std.testing.expectError(error.InvalidEndpoint, io.socketAddress(.{ .address = invalid, .proto = .init(.udp, 1194) }));
    }
}
