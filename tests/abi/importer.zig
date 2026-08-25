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
        core.ImportContext.init(null, null),
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
        core.ImportContext.init(null, null),
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
    , core.ImportContext.init(null, null));
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
    , core.ImportContext.init(null, null));
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
            core.ImportContext.init(&info, null),
        ),
    );
    try std.testing.expectEqualStrings("PrivateKey", info.name.?);
    try std.testing.expectEqualStrings("PrivateKey = nope", info.line.?);
    try std.testing.expectEqual(@as(usize, 1), info.arguments.len);
    try std.testing.expectEqualStrings("nope", info.arguments[0]);
    try std.testing.expectEqualStrings(
        api.WireGuardErrorCode.interfaceHasInvalidPrivateKey.raw(),
        info.sub_code.?,
    );
}

test "ABI importer reports parse error info for raw profiles" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.Parsing,
        importer.importProfile(
            allocator,
            \\[Interface]
            \\PrivateKey = nope
        ,
            null,
            core.ImportContext.init(&info, null),
        ),
    );
    try std.testing.expectEqualStrings("PrivateKey", info.name.?);
    try std.testing.expectEqualStrings("PrivateKey = nope", info.line.?);
    try std.testing.expectEqual(@as(usize, 1), info.arguments.len);
    try std.testing.expectEqualStrings("nope", info.arguments[0]);
    try std.testing.expectEqualStrings(
        api.WireGuardErrorCode.interfaceHasInvalidPrivateKey.raw(),
        info.sub_code.?,
    );
}

test "ABI importer preserves OpenVPN parse error codes" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    var module_info: api.ParseErrorInfo = .{};
    defer module_info.deinit(allocator);
    try std.testing.expectError(
        error.Parsing,
        importer.importModule(
            allocator,
            invalid_openvpn_profile,
            core.ImportContext.init(&module_info, null),
        ),
    );
    try std.testing.expectEqualStrings(
        api.OpenVPNErrorCode.unsupportedCompression.raw(),
        module_info.sub_code.?,
    );

    var profile_info: api.ParseErrorInfo = .{};
    defer profile_info.deinit(allocator);
    try std.testing.expectError(
        error.Parsing,
        importer.importProfile(
            allocator,
            invalid_openvpn_profile,
            null,
            core.ImportContext.init(&profile_info, null),
        ),
    );
    try std.testing.expectEqualStrings(
        api.OpenVPNErrorCode.unsupportedCompression.raw(),
        profile_info.sub_code.?,
    );

    var passphrase_info: api.ParseErrorInfo = .{};
    defer passphrase_info.deinit(allocator);
    try std.testing.expectError(
        error.Parsing,
        importer.importModule(
            allocator,
            encrypted_openvpn_profile,
            core.ImportContext.init(&passphrase_info, null),
        ),
    );
    try std.testing.expectEqualStrings(
        api.OpenVPNErrorCode.passphraseRequired.raw(),
        passphrase_info.sub_code.?,
    );
    try std.testing.expect(passphrase_info.name == null);
    try std.testing.expect(passphrase_info.line == null);
    try std.testing.expectEqual(@as(usize, 0), passphrase_info.arguments.len);
}

test "ABI importer preserves parsing without a sub-code" {
    const allocator = std.testing.allocator;

    var importer = try Importer.init(allocator);
    defer importer.deinit(allocator);
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.Parsing,
        importer.importProfile(
            allocator,
            "cipher",
            null,
            core.ImportContext.init(&info, null),
        ),
    );
    try std.testing.expect(info.sub_code == null);
}

test "profile import export returns normalized success and failure payloads" {
    try expectImportEnvelope(
        partout.partout_import_profile(valid_wireguard_profile, "Imported WireGuard"),
        null,
        "name",
        "Imported WireGuard",
    );
    try expectImportEnvelope(
        partout.partout_import_profile(invalid_wireguard_profile, null),
        .parsing,
        null,
        null,
    );
    try expectImportEnvelope(
        partout.partout_import_profile(invalid_openvpn_profile, null),
        .parsing,
        null,
        null,
    );
    try expectImportEnvelope(
        partout.partout_import_profile(encrypted_openvpn_profile, null),
        .parsing,
        null,
        null,
    );
}

test "module import export returns normalized success and failure payloads" {
    try expectImportEnvelope(
        partout.partout_import_module(valid_wireguard_profile),
        null,
        "type",
        "WireGuard",
    );
    try expectImportEnvelope(
        partout.partout_import_module(invalid_wireguard_profile),
        .parsing,
        null,
        null,
    );
    try expectImportEnvelope(
        partout.partout_import_module(invalid_openvpn_profile),
        .parsing,
        null,
        null,
    );
    try expectImportEnvelope(
        partout.partout_import_module(encrypted_openvpn_profile),
        .parsing,
        null,
        null,
    );
}

fn expectImportEnvelope(
    c_result: ?[*:0]u8,
    expected_code: ?api.PartoutErrorCode,
    expected_payload_key: ?[]const u8,
    expected_payload_value: ?[]const u8,
) !void {
    const result_ptr = c_result orelse return error.TestUnexpectedResult;
    const result_json = std.mem.span(result_ptr);
    defer std.heap.c_allocator.free(result_json);

    var envelope = try api.ABIEnvelope.parse(std.testing.allocator, result_json);
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected_code, envelope.code);

    const expected_key = expected_payload_key orelse return;
    const expected_value = expected_payload_value orelse return error.TestUnexpectedResult;
    var parsed_payload = try core.util.parseJsonValue(
        std.testing.allocator,
        envelope.payload.?.bytes,
    );
    defer parsed_payload.deinit();
    const payload = parsed_payload.value.object;
    try std.testing.expectEqualStrings(
        expected_value,
        payload.get(expected_key).?.string,
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
    \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
    \\[Peer]
    \\AllowedIPs = 0.0.0.0/0
;

const invalid_openvpn_profile = "compress lzo";

const encrypted_openvpn_profile =
    \\client
    \\<key>
    \\-----BEGIN PRIVATE KEY-----
    \\Proc-Type: 4,ENCRYPTED
    \\DEK-Info: AES-256-CBC,0123456789ABCDEF
    \\ciphertext
    \\-----END PRIVATE KEY-----
    \\</key>
;
