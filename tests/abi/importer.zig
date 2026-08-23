// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const conn = @import("source").net_connection;
const core = @import("source").core;

const api = core.api;

const Importer = @import("source").abi.Importer;
const partout = @import("source").partout;

test "ABI registry imports raw OpenVPN profile through parser implementation" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    const imported = try importer.importProfile(
        allocator,
        \\client
        \\remote vpn.example.com 1194 udp
        \\auth-user-pass
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</ca>
    ,
        "Imported OpenVPN",
        core.ImportContext.init(null, null, null),
    );
    defer allocator.free(imported);

    try std.testing.expectEqual(@as(u8, 0), imported[imported.len]);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"name\":\"Imported OpenVPN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"OpenVPN\"") != null);
    var profile = try api.Profile.parse(allocator, imported);
    defer profile.deinit(allocator);
    const module = conn.activeConnectionModule(&profile) orelse return error.TestUnexpectedResult;
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
        core.ImportContext.init(null, null, null),
    );
    defer allocator.free(imported);

    try std.testing.expect(std.mem.indexOf(u8, imported, "\"name\":\"Imported WireGuard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"WireGuard\"") != null);
    var profile = try api.Profile.parse(allocator, imported);
    defer profile.deinit(allocator);
    const module = conn.activeConnectionModule(&profile) orelse return error.TestUnexpectedResult;
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
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</ca>
    , core.ImportContext.init(null, null, null));
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
    , core.ImportContext.init(null, null, null));
    defer allocator.free(imported);

    try std.testing.expect(std.mem.indexOf(u8, imported, "\"type\":\"WireGuard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, imported, "\"id\":\"") != null);
}

test "ABI importer reports parse error info for raw modules" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.Parsing,
        importer.importModule(
            allocator,
            \\[Interface]
            \\PrivateKey = nope
        ,
            core.ImportContext.init(&info, null, null),
        ),
    );
    try std.testing.expectEqualStrings("PrivateKey", info.name);
    try std.testing.expectEqualStrings("PrivateKey = nope", info.details);
}

test "ABI importer reports parse error info for raw profiles" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.InvalidProfile,
        importer.importProfile(
            allocator,
            \\[Interface]
            \\PrivateKey = nope
        ,
            null,
            core.ImportContext.init(&info, null, null),
        ),
    );
    try std.testing.expectEqualStrings("PrivateKey", info.name);
    try std.testing.expectEqualStrings("PrivateKey = nope", info.details);
}

test "profile import export returns normalized success and failure payloads" {
    try expectImportEnvelope(
        partout.partout_import_profile(valid_wireguard_profile, "Imported WireGuard"),
        0,
        "name",
        "Imported WireGuard",
    );
    try expectImportEnvelope(
        partout.partout_import_profile(invalid_wireguard_profile, null),
        -1,
        "code",
        "decoding",
    );
}

test "module import export returns normalized success and failure payloads" {
    try expectImportEnvelope(
        partout.partout_import_module(valid_wireguard_profile),
        0,
        "type",
        "WireGuard",
    );
    try expectImportEnvelope(
        partout.partout_import_module(invalid_wireguard_profile),
        -1,
        "code",
        "parsing",
    );
}

fn expectImportEnvelope(
    c_result: ?[*:0]u8,
    expected_code: i32,
    expected_payload_key: []const u8,
    expected_payload_value: []const u8,
) !void {
    const result_ptr = c_result orelse return error.TestUnexpectedResult;
    const result_json = std.mem.span(result_ptr);
    defer std.heap.c_allocator.free(result_json);

    var envelope = try api.ABIEnvelope.parse(std.testing.allocator, result_json);
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected_code, envelope.code);

    var parsed_payload = try core.util.parseJsonValue(
        std.testing.allocator,
        envelope.payload.bytes,
    );
    defer parsed_payload.deinit();
    const payload = parsed_payload.value.object;
    try std.testing.expectEqualStrings(
        expected_payload_value,
        payload.get(expected_payload_key).?.string,
    );
}

const valid_wireguard_profile =
    \\[Interface]
    \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
    \\Address = 10.0.0.2/32
    \\
    \\[Peer]
    \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
    \\AllowedIPs = 0.0.0.0/0
    \\Endpoint = wg.example.com:51820
;

const invalid_wireguard_profile =
    \\[Interface]
    \\PrivateKey = nope
;
