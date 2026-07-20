// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const exports = @import("source").openvpn_exports;
const parser = @import("source").openvpn_parser;

const api = core.api;

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
    ,
        null,
    );
    defer module.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.OpenVPN, api.moduleType(&module));
    const module_id = api.moduleId(&module);
    try std.testing.expect(core.isGeneratedId(module_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, module_id[0..], "openvpn"));

    const encoded = try api.encodeModule(allocator, module);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"OpenVPN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"remotes\":[\"vpn.example.com:UDP:1194\"]") != null);
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
    // ZIGME: Restore after mapping code
    // try std.testing.expectEqual(
    //     api.PartoutErrorCode.openVPNPassphraseRequired,
    //     api.codeForError(error.PassphraseRequired),
    // );
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
