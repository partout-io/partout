// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const util = source.core.util;

test "OpenVPN configuration JSON exposes populated fields and omits nil fields" {
    const allocator = std.testing.allocator;
    const remotes = [_]api.ExtendedEndpoint{
        api.ExtendedEndpoint.init("vpn.example.com", .init(.udp, 1194)).?,
    };
    const ca_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
    const secure = api.SecureData{ .base64 = "AQID" };
    const configuration = api.OpenVPNConfiguration{
        .remotes = &remotes,
        .randomize_endpoint = true,
        .auth_user_pass = true,
        .renegotiates_after = 0,
        .cipher = .aes256cbc,
        .digest = .sha512,
        .ca = .{ .pem = ca_pem },
        .tls_wrap = .{
            .strategy = .auth,
            .key = .{ .data = secure, .dir = .client },
        },
        .xor_method = .{ .obfuscate = .{ .mask = secure } },
        .mtu = 1500,
        .checks_eku = true,
    };
    const encoded = try util.encodeJsonValue(allocator, configuration);
    defer allocator.free(encoded);
    var parsed = try util.parseJsonValue(allocator, encoded);
    defer parsed.deinit();
    const object = parsed.value.object;

    const populated = [_][]const u8{
        "remotes",
        "randomizeEndpoint",
        "authUserPass",
        "renegotiatesAfter",
        "cipher",
        "digest",
        "ca",
        "tlsWrap",
        "xorMethod",
        "mtu",
        "checksEKU",
    };
    for (populated) |field| try std.testing.expect(object.get(field) != null);
    try std.testing.expect(object.get("dnsServers") == null);
    try std.testing.expect(object.get("clientCertificate") == null);
    try std.testing.expect(object.get("clientKey") == null);
    try std.testing.expectEqualStrings(ca_pem, object.get("ca").?.string);
    try std.testing.expectEqualStrings(
        "AQID",
        object.get("tlsWrap").?.object.get("key").?.object.get("data").?.string,
    );
    try std.testing.expectEqualStrings(
        "AQID",
        object.get("xorMethod").?.object.get("mask").?.string,
    );
    try std.testing.expectEqualStrings(
        "vpn.example.com:UDP:1194",
        object.get("remotes").?.array.items[0].string,
    );
}

test "OpenVPN obfuscation methods round trip tagged JSON" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"xormask","mask":"AQID"}
        ,
        \\{"type":"xorptrpos"}
        ,
        \\{"type":"reverse"}
        ,
        \\{"type":"obfuscate","mask":"AQID"}
        ,
    };

    for (cases) |encoded| {
        var value = try api.OpenVPNObfuscationMethod.parse(allocator, encoded);
        defer value.deinit(allocator);
        const round_trip = try util.encodeJsonValue(allocator, value);
        defer allocator.free(round_trip);
        var decoded = try api.OpenVPNObfuscationMethod.parse(allocator, round_trip);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(std.meta.activeTag(value), std.meta.activeTag(decoded));
    }
}

test "OpenVPN obfuscation masks preserve decoded bytes" {
    const allocator = std.testing.allocator;
    var xormask = try api.OpenVPNObfuscationMethod.parse(allocator,
        \\{"type":"xormask","mask":"AQID"}
    );
    defer xormask.deinit(allocator);
    const mask = switch (xormask) {
        .xormask => |value| value.mask,
        else => return error.TestUnexpectedResult,
    };
    const bytes = try mask.bytesAlloc(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, bytes);
}

test "OpenVPN obfuscation methods reject malformed tagged masks" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidModel,
        api.OpenVPNObfuscationMethod.parse(allocator, "{\"type\":\"xormask\"}"),
    );
    try std.testing.expectError(
        error.InvalidModel,
        api.OpenVPNObfuscationMethod.parse(allocator, "{\"type\":\"obfuscate\"}"),
    );
}
