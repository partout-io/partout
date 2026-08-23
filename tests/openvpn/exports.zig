// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");

const core = source.core;
const exports = source.openvpn_exports;
const parser = source.openvpn_parser;

const api = core.api;
const has_openssl_backend =
    @hasDecl(source.c_crypto, "PARTOUT_CRYPTO_OPENSSL");
const has_real_default_crypto_backend =
    has_openssl_backend or
    @hasDecl(source.c_crypto, "PARTOUT_CRYPTO_MBEDTLS");

test "OpenVPN module exports import tagged module" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;

    try std.testing.expectEqual(
        api.ModuleType.OpenVPN,
        module_implementation.moduleType(),
    );

    var module = try module_implementation.importModule(
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
        null,
    );
    defer module.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.OpenVPN, api.moduleType(&module));
    const module_id = api.moduleId(&module);
    try std.testing.expect(core.isGeneratedId(module_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, module_id[0..], "openvpn"));

    const encoded = try api.encodeModule(allocator, &module);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"OpenVPN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"remotes\":[\"vpn.example.com:UDP:1194\"]") != null);
}

test "OpenVPN module importer requires CA and at least one remote" {
    const allocator = std.testing.allocator;
    const module_implementation = exports.impl.module;

    try std.testing.expectError(
        error.Parsing,
        module_implementation.importModule(
            allocator,
            "client\nremote vpn.example.com 1194 udp",
            null,
        ),
    );
    try std.testing.expectError(
        error.Parsing,
        module_implementation.importModule(
            allocator,
            \\client
            \\<ca>
            \\-----BEGIN CERTIFICATE-----
            \\abc
            \\-----END CERTIFICATE-----
            \\</ca>
        ,
            null,
        ),
    );
}

test "OpenVPN module importer reports generic parse error info" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.Parsing,
        module_implementation.importModule(
            allocator,
            "compress lzo",
            core.ImportContext.init(&info, null, null),
        ),
    );

    try std.testing.expectEqualStrings("compress", info.name);
    try std.testing.expectEqualStrings("compress lzo", info.details);
}

test "OpenVPN module importer accepts protocol context pointer" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;
    var context = parser.Parser.Context{ .passphrase = "secret" };
    const import_context = core.ImportContext.init(null, null, @ptrCast(&context));
    try std.testing.expect(import_context.cast(parser.Parser.Context, .OpenVPN) == null);
    try std.testing.expectEqualStrings(
        "secret",
        import_context.withModuleType(.OpenVPN).cast(parser.Parser.Context, .OpenVPN).?.passphrase.?,
    );

    var module = try module_implementation.importModule(
        allocator,
        \\client
        \\remote vpn.example.com 1194 udp
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</ca>
    ,
        import_context,
    );
    defer module.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.OpenVPN, api.moduleType(&module));
}

test "OpenVPN module importer reports passphrase requirement" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;
    var recognized_type: api.ModuleType = undefined;

    try std.testing.expectError(
        error.PassphraseRequired,
        module_implementation.importModule(
            allocator,
            encrypted_key_configuration,
            core.ImportContext.init(null, &recognized_type, null),
        ),
    );

    try std.testing.expectEqual(api.ModuleType.OpenVPN, recognized_type);
}

test "OpenVPN module importer decrypts legacy PKCS#1 client keys" {
    if (!has_real_default_crypto_backend) return error.SkipZigTest;
    try expectDefaultImporterDecrypts(tunnelbear_pkcs1);
}

test "OpenVPN module importer decrypts PKCS#8 client keys" {
    if (!has_real_default_crypto_backend) return error.SkipZigTest;
    try expectDefaultImporterDecrypts(tunnelbear_aes256_pkcs8);
}

test "OpenVPN module importer decrypts legacy TripleDES PKCS#8 client keys with OpenSSL" {
    if (!has_openssl_backend) return error.SkipZigTest;
    try expectDefaultImporterDecrypts(tunnelbear_legacy_pkcs8);
}

test "OpenVPN module importer rejects a wrong encrypted-key passphrase" {
    if (!has_real_default_crypto_backend) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var parser_context = parser.Parser.Context{ .passphrase = "wrong" };
    if (exports.impl.module.importModule(
        allocator,
        tunnelbear_aes256_pkcs8,
        core.ImportContext.init(
            null,
            null,
            @ptrCast(&parser_context),
        ).withModuleType(.OpenVPN),
    )) |imported| {
        var module = imported;
        module.deinit(allocator);
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectDefaultImporterDecrypts(contents: []const u8) !void {
    const allocator = std.testing.allocator;
    const module_implementation = exports.impl.module;
    var parser_context = parser.Parser.Context{ .passphrase = "foobar" };
    var module = try module_implementation.importModule(
        allocator,
        contents,
        core.ImportContext.init(
            null,
            null,
            @ptrCast(&parser_context),
        ).withModuleType(.OpenVPN),
    );
    defer module.deinit(allocator);

    const openvpn = switch (module) {
        .OpenVPN => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const client_key = openvpn.configuration.?.client_key.?;
    try std.testing.expect(!client_key.isEncrypted());
    try std.testing.expectEqualStrings(tunnelbear_decrypted, client_key.pem);
}

const encrypted_key_configuration =
    \\client
    \\<key>
    \\-----BEGIN PRIVATE KEY-----
    \\Proc-Type: 4,ENCRYPTED
    \\DEK-Info: AES-256-CBC,0123456789ABCDEF
    \\ciphertext
    \\-----END PRIVATE KEY-----
    \\</key>
;

const encrypted_client_prefix =
    \\client
    \\remote vpn.example.com 1194 udp
    \\<ca>
    \\-----BEGIN CERTIFICATE-----
    \\test
    \\-----END CERTIFICATE-----
    \\</ca>
    \\<key>
;
const tunnelbear_pkcs1 = encrypted_client_prefix ++ "\n" ++
    @embedFile("fixtures/tunnelbear.enc.1.key") ++ "\n</key>";
const tunnelbear_aes256_pkcs8 = encrypted_client_prefix ++ "\n" ++
    @embedFile("fixtures/tunnelbear.aes256.enc.8.key") ++ "\n</key>";
const tunnelbear_legacy_pkcs8 = encrypted_client_prefix ++ "\n" ++
    @embedFile("fixtures/tunnelbear.enc.8.key") ++ "\n</key>";
const tunnelbear_decrypted = @embedFile("fixtures/tunnelbear.key");
