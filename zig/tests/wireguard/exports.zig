// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const exports = @import("source").wireguard_exports;

const api = core.api;

test "WireGuard module exports import tagged module" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;

    try std.testing.expectEqual(
        api.ModuleType.WireGuard,
        module_implementation.moduleType(),
    );

    var module = try module_implementation.importModule(
        allocator,
        \\[Interface]
        \\PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
        \\Address = 10.0.0.2/32
        \\DNS = 1.1.1.1, example.com
        \\
        \\[Peer]
        \\PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
        \\AllowedIPs = 0.0.0.0/0
        \\Endpoint = wg.example.com:51820
    ,
        null,
    );
    defer module.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.WireGuard, api.moduleType(&module));
    const module_id = api.moduleId(&module);
    try std.testing.expect(core.isGeneratedId(module_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, module_id[0..], "wireguard"));

    const encoded = try api.encodeModule(allocator, module);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"WireGuard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"servers\":[\"1.1.1.1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"searchDomains\":[\"example.com\"]") != null);
}

test "WireGuard module importer reports generic parse error info" {
    const allocator = std.testing.allocator;

    const module_implementation = exports.impl.module;
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        error.Parsing,
        module_implementation.importModule(
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
