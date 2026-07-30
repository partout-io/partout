// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const parser = @import("source").wireguard_parser;

const api = core.api;
const WireGuardParser = parser.Parser;

test "WireGuardParser parses wg-quick configuration" {
    const allocator = std.testing.allocator;
    var configuration = try WireGuardParser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\ListenPort = 51820
        \\Address = 10.8.0.6/24, fd00::1/64
        \\DNS = 1.1.1.1, example.com
        \\MTU = 1420
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\PresharedKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\AllowedIPs = 0.0.0.0/0, ::/0
        \\Endpoint = [1:2:3::4]:12345
        \\PersistentKeepalive = 25
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqualStrings("4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=", configuration.interface.private_key.raw);
    try std.testing.expectEqual(@as(usize, 2), configuration.interface.addresses.len);
    try std.testing.expectEqual(@as(u16, 51820), configuration.interface.listen_port.?);
    try std.testing.expectEqual(@as(u16, 1420), configuration.interface.mtu.?);
    try std.testing.expectEqual(@as(usize, 1), configuration.peers.len);
    try std.testing.expectEqualStrings("1:2:3::4", configuration.peers[0].endpoint.?.address);
    try std.testing.expectEqual(@as(u16, 12345), configuration.peers[0].endpoint.?.port);
}

test "WireGuardParser reports parse error info" {
    try expectParseErrorInfo(
        error.InvalidLine,
        "this is not wg",
        "",
        "this is not wg",
    );
    try expectParseErrorInfo(
        error.InterfaceHasInvalidPrivateKey,
        \\[Interface]
        \\PrivateKey = nope
    ,
        "PrivateKey",
        "PrivateKey = nope",
    );
    try expectParseErrorInfo(
        error.InterfaceHasInvalidListenPort,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\ListenPort = nope
    ,
        "ListenPort",
        "ListenPort = nope",
    );
    try expectParseErrorInfo(
        error.PeerHasInvalidAllowedIP,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\AllowedIPs = nope
    ,
        "AllowedIPs",
        "AllowedIPs = nope",
    );
    try expectParseErrorInfo(
        error.PeerHasUnrecognizedKey,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\Bogus = yep
    ,
        "Bogus",
        "Bogus = yep",
    );
    try expectParseErrorInfo(
        error.MultipleInterfaces,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\[Interface]
    ,
        "",
        "[Interface]",
    );
    try expectParseErrorInfo(
        error.PeerHasNoPublicKey,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\[Peer]
        \\AllowedIPs = 0.0.0.0/0
    ,
        "AllowedIPs",
        "AllowedIPs = 0.0.0.0/0",
    );
}

test "WireGuardParser accepts repeated list keys" {
    const allocator = std.testing.allocator;
    var configuration = try WireGuardParser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\Address = 10.8.0.6/24
        \\Address = fd00::1/64
        \\DNS = 1.1.1.1
        \\DNS = example.com
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\AllowedIPs = 0.0.0.0/0
        \\AllowedIPs = ::/0
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), configuration.interface.addresses.len);
    try std.testing.expectEqual(@as(usize, 1), configuration.interface.dns.?.servers.len);
    try std.testing.expectEqual(@as(usize, 1), configuration.interface.dns.?.search_domains.?.len);
    try std.testing.expectEqual(@as(usize, 2), configuration.peers[0].allowed_ips.len);
}

test "WireGuardParser retains ListenPort and accepts legacy DNS keys" {
    const allocator = std.testing.allocator;
    var configuration = try WireGuardParser.parse(allocator,
        \\# Exported by a wg-quick-compatible provider
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw= # device key
        \\ListenPort = 51820
        \\DNSOverHTTPSURL = https://resolver.example/dns-query
        \\DNSOverTLSServerName = resolver.example
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 51820), configuration.interface.listen_port.?);
    // The protocol-specific DNS extension keys remain accepted and discarded,
    // as in Swift; modern DNS protocol settings live in a nested DNS module.
    try std.testing.expectEqual(@as(usize, 1), configuration.peers.len);
}

test "WireGuardParser requires an interface section" {
    try std.testing.expectError(error.NoInterface, WireGuardParser.parse(std.testing.allocator, ""));
}

test "WireGuardParser rejects duplicate peer public keys" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MultiplePeersWithSamePublicKey, WireGuardParser.parse(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
    ));
}

test "WireGuardParser enforces wg-quick endpoint grammar" {
    const allocator = std.testing.allocator;
    const invalid_endpoints = [_][]const u8{
        // IPv6 is ambiguous unless it uses WireGuard's bracketed form.
        "2001:db8::1:51820",
        // These are rejected by Swift's URL-host character validation too.
        "example .com:51820",
        "example.com/path:51820",
        // A closing bracket must be followed immediately by the port colon.
        "[2001:db8::1]51820",
    };

    for (invalid_endpoints) |endpoint| {
        const contents = try std.fmt.allocPrint(allocator,
            \\[Interface]
            \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
            \\[Peer]
            \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
            \\Endpoint = {s}
        , .{endpoint});
        defer allocator.free(contents);
        try std.testing.expectError(
            error.PeerHasInvalidEndpoint,
            WireGuardParser.parse(allocator, contents),
        );
    }
}

test "WireGuardParser matches sections and keys case-insensitively" {
    const allocator = std.testing.allocator;
    var configuration = try WireGuardParser.parse(allocator,
        \\[INTERFACE]
        \\pRiVaTeKeY = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\aDdReSs = 10.8.0.6/24
        \\dNs = 1.1.1.1
        \\
        \\[pEeR]
        \\pUbLiCkEy = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\aLlOwEdIpS = 0.0.0.0/0
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), configuration.interface.addresses.len);
    try std.testing.expectEqual(@as(usize, 1), configuration.interface.dns.?.servers.len);
    try std.testing.expectEqual(@as(usize, 1), configuration.peers.len);
    try std.testing.expectEqual(@as(usize, 1), configuration.peers[0].allowed_ips.len);
}

fn expectParseErrorInfo(
    expected_err: anyerror,
    contents: []const u8,
    expected_name: []const u8,
    expected_line: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        expected_err,
        (WireGuardParser{}).parseWithContext(allocator, contents, .{
            .parse_error_info = &info,
        }),
    );
    try std.testing.expectEqualStrings(expected_name, info.name);
    try std.testing.expectEqualStrings(expected_line, info.details);
}
