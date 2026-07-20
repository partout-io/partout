// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const conn = @import("source").net_connection;
const core = @import("source").core;

const api = core.api;

const Importer = @import("source").abi.Importer;
test "ABI registry imports raw OpenVPN profile through parser implementation" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    const imported = try importer.importProfile(
        allocator,
        \\client
        \\remote vpn.example.com 1194 udp
        \\auth-user-pass
    ,
        "Imported OpenVPN",
    );
    defer allocator.free(imported);

    try std.testing.expectEqual(@as(u8, 0), imported[imported.len]);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"name\":\"Imported OpenVPN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"OpenVPN\"") != null);
    var profile = try api.Profile.parse(allocator, imported);
    defer profile.deinit(allocator);
    const module = conn.activeConnectionModule(profile) orelse return error.TestUnexpectedResult;
    const module_id = module.id();
    try std.testing.expect(core.isGeneratedId(module_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, module_id[0..], "openvpn"));
}

test "ABI registry imports raw WireGuard profile through parser implementation" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    const imported = try importer.importProfile(
        allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\Address = 10.0.0.2/32
        \\DNS = 1.1.1.1
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\AllowedIPs = 0.0.0.0/0
        \\Endpoint = wg.example.com:51820
    ,
        "Imported WireGuard",
    );
    defer allocator.free(imported);

    try std.testing.expect(std.mem.indexOf(u8, imported, "\"name\":\"Imported WireGuard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"WireGuard\"") != null);
    var profile = try api.Profile.parse(allocator, imported);
    defer profile.deinit(allocator);
    const module = conn.activeConnectionModule(profile) orelse return error.TestUnexpectedResult;
    const module_id = module.id();
    try std.testing.expect(core.isGeneratedId(module_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, module_id[0..], "wireguard"));
}

test "ABI registry imports raw OpenVPN module through parser implementation" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    const imported = try importer.importModule(allocator,
        \\client
        \\remote vpn.example.com 1194 udp
        \\auth-user-pass
    );
    defer allocator.free(imported);

    try std.testing.expectEqual(@as(u8, 0), imported[imported.len]);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"OpenVPN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"id\":\"") != null);
}

test "ABI registry imports raw WireGuard module through parser implementation" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    const imported = try importer.importModule(allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\Address = 10.0.0.2/32
        \\DNS = 1.1.1.1
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\AllowedIPs = 0.0.0.0/0
        \\Endpoint = wg.example.com:51820
    );
    defer allocator.free(imported);

    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"WireGuard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"id\":\"") != null);
}
