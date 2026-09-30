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

test "SocketEndpoint preserves transport and formats owned-by-caller IP text" {
    const api = @import("source").core.api;
    const cases = [_]struct { text: []const u8, transport: api.IPSocketType, family: api.Address.Family }{
        .{ .text = "192.0.2.1", .transport = .udp, .family = .v4 },
        .{ .text = "192.0.2.1", .transport = .udp4, .family = .v4 },
        .{ .text = "192.0.2.1", .transport = .tcp, .family = .v4 },
        .{ .text = "192.0.2.1", .transport = .tcp4, .family = .v4 },
        .{ .text = "2001:db8::1", .transport = .tcp6, .family = .v6 },
        .{ .text = "fe80::1%12", .transport = .udp6, .family = .v6 },
    };
    for (cases) |case| {
        const endpoint = try io.SocketEndpoint.init(.{ .address = case.text, .proto = .init(case.transport, 1194) });
        try std.testing.expectEqual(case.transport, endpoint.type);
        try std.testing.expectEqual(if (case.transport == .tcp or case.transport == .tcp4 or case.transport == .tcp6) io.SocketType.tcp else .udp, endpoint.plainSocketType());
        var buffer: [64]u8 = undefined;
        const address = try endpoint.ipAddress(&buffer);
        try std.testing.expectEqualStrings(case.text, address.raw);
        try std.testing.expectEqual(case.family, address.family);
        try std.testing.expect(!address.owned);
        const roundtrip = try io.SocketEndpoint.init(.{ .address = address.raw, .proto = .init(case.transport, endpoint.address.port) });
        try std.testing.expectEqualDeep(endpoint, roundtrip);
        var tiny: [1]u8 = undefined;
        try std.testing.expectError(error.NoSpaceLeft, endpoint.ipAddress(&tiny));
    }
    try std.testing.expectError(error.InvalidEndpoint, io.SocketEndpoint.init(.{ .address = "vpn.example.com", .proto = .init(.udp, 1194) }));
}
