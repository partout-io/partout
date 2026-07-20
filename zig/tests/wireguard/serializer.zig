// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");

const api = source.core.api;
const Parser = source.wireguard_parser.Parser;
const serializer = source.wireguard_serializer;

test "WireGuard serializer generates wg-quick configuration" {
    const allocator = std.testing.allocator;
    var configuration = try Parser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\ListenPort = 51820
        \\Address = 10.8.0.6/24, fd00::1/64
        \\DNS = 1.1.1.1, example.com
        \\MTU = 1420
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\PresharedKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\AllowedIPs = 0.0.0.0/0, ::/0
        \\Endpoint = [1:2:3::4]:12345
        \\PersistentKeepalive = 25
    );
    defer configuration.deinit(allocator);

    const serialized = try serializer.serializeConfiguration(allocator, configuration);
    defer allocator.free(serialized);

    try std.testing.expectEqualStrings(
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\ListenPort = 51820
        \\Address = 10.8.0.6/24,fd00::1/64
        \\DNS = 1.1.1.1,example.com
        \\MTU = 1420
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\PresharedKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\AllowedIPs = 0.0.0.0/0,::/0
        \\Endpoint = [1:2:3::4]:12345
        \\PersistentKeepalive = 25
    , serialized);

    var reparsed = try Parser.parse(allocator, serialized);
    defer reparsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), reparsed.interface.addresses.len);
    try std.testing.expectEqual(@as(usize, 1), reparsed.peers.len);
    try std.testing.expectEqual(@as(u16, 51820), reparsed.interface.listen_port.?);
    try std.testing.expectEqual(@as(usize, 2), reparsed.peers[0].allowed_ips.len);
}

test "WireGuard module export serializes module configuration" {
    const allocator = std.testing.allocator;
    var configuration = try Parser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
    );
    defer configuration.deinit(allocator);

    const module = api.TaggedModule{ .WireGuard = .{ .configuration = configuration } };
    const serialized = try source.wireguard_exports.impl.module.serializeModule(allocator, module, null);
    defer allocator.free(serialized);

    try std.testing.expectEqualStrings(
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
    , serialized);
}

test "WireGuard serializer validates required keys and DNS roles" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.IncompleteModule,
        serializer.serializeConfiguration(allocator, .{}),
    );

    const invalid_dns = api.WireGuardConfiguration{ .interface = .{
        .private_key = api.WireGuardKey.parseRaw("4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=").?,
        .dns = .{
            .servers = &.{api.Address.parseRaw("example.com").?},
        },
    } };
    try std.testing.expectError(
        error.SerializationFailed,
        serializer.serializeConfiguration(allocator, invalid_dns),
    );
}

test "WireGuard serializer retains ListenPort and discards legacy DNS keys" {
    const allocator = std.testing.allocator;
    var configuration = try Parser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\ListenPort = 51820
        \\DNSOverHTTPSURL = https://resolver.example/dns-query
        \\DNSOverTLSServerName = resolver.example
    );
    defer configuration.deinit(allocator);

    const serialized = try serializer.serializeConfiguration(allocator, configuration);
    defer allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "ListenPort = 51820") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "DNSOverHTTPSURL") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "DNSOverTLSServerName") == null);
}
