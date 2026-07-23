// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const parser = @import("source").openvpn_parser;

const api = core.api;

const OpenVPNParser = parser.Parser;
test "OpenVPNParser parses common client configuration" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\client
        \\proto tcp
        \\port 443
        \\remote vpn.example.com
        \\cipher AES-256-CBC
        \\data-ciphers AES-256-GCM:AES-128-GCM
        \\auth SHA256
        \\auth-user-pass
        \\comp-lzo no
        \\keepalive 10 60
        \\remote-cert-tls server
        \\remote-random
        \\dhcp-option DNS 1.1.1.1
        \\dhcp-option DOMAIN example.com
        \\dhcp-option DOMAIN-SEARCH internal.example.com
        \\redirect-gateway def1 block-local
        \\scramble reverse
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</ca>
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, configuration.cipher.?);
    try std.testing.expectEqual(@as(usize, 2), configuration.data_ciphers.?.len);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, configuration.digest.?);
    try std.testing.expectEqual(@as(usize, 1), configuration.remotes.?.len);
    try std.testing.expectEqual(api.IPSocketType.tcp, configuration.remotes.?[0].proto.socket_type);
    try std.testing.expectEqual(@as(u16, 443), configuration.remotes.?[0].proto.port);
    try std.testing.expectEqualStrings("vpn.example.com", configuration.remotes.?[0].address);
    try std.testing.expectEqual(@as(usize, 1), configuration.dns_servers.?.len);
    try std.testing.expectEqual(api.OpenVPNRoutingPolicy.IPv4, configuration.routing_policies.?[0]);
    try std.testing.expectEqual(api.OpenVPNRoutingPolicy.blockLocal, configuration.routing_policies.?[1]);
    try std.testing.expect(configuration.xor_method.? == .reverse);
}

test "OpenVPNParser rejects enabled LZO compression" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedCompression, OpenVPNParser.parse(allocator, "comp-lzo"));
    try std.testing.expectError(error.UnsupportedCompression, OpenVPNParser.parse(allocator, "compress lzo"));
}

test "OpenVPNParser stores scramble masks as UTF-8 SecureData" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator, "scramble obfuscate FFFF");
    defer configuration.deinit(allocator);

    const mask = switch (configuration.xor_method.?) {
        .obfuscate => |value| value.mask,
        else => return error.TestUnexpectedResult,
    };
    const bytes = try mask.bytesAlloc(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("FFFF", bytes);
    try std.testing.expectEqualStrings("RkZGRg==", mask.base64);
}

test "OpenVPNParser reports parse error info" {
    try expectParseErrorInfo(error.MalformedOption, "cipher", "cipher", "cipher");
    try expectParseErrorInfo(error.UnsupportedCompression, "compress lzo", "compress", "compress lzo");
    try expectParseErrorInfo(error.UnsupportedConfiguration, "proto sctp", "proto", "proto sctp");
}

test "OpenVPNParser matches directives and inline blocks case-insensitively" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\PrOtO TCP
        \\PoRt 443
        \\ReMoTe vpn.example.com
        \\RoUtE 10.0.0.0 255.255.255.0 VPN_GATEWAY
        \\<CA>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</cA>
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), configuration.remotes.?.len);
    try std.testing.expectEqual(api.IPSocketType.tcp, configuration.remotes.?[0].proto.socket_type);
    try std.testing.expectEqual(@as(u16, 443), configuration.remotes.?[0].proto.port);
    try std.testing.expectEqual(@as(usize, 1), configuration.routes4.?.len);
    try std.testing.expect(configuration.routes4.?[0].gateway == null);
    try std.testing.expect(configuration.ca != null);
}

test "OpenVPNParser builds subnet IPv4 and IPv6 settings from push directives" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\topology subnet
        \\ifconfig 10.8.12.34 255.255.255.0
        \\route-gateway 10.8.12.1
        \\ifconfig-ipv6 fd42:abcd:1234::9/64 fd42:abcd:1234::1
        \\route-ipv6-gateway fd42:abcd:1234::ffff
    );
    defer configuration.deinit(allocator);

    const ipv4 = configuration.ipv4 orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), ipv4.subnets.len);
    try std.testing.expectEqualStrings("10.8.12.34", ipv4.subnets[0].address.raw);
    try std.testing.expectEqual(@as(u8, 24), ipv4.subnets[0].prefix_length);
    try std.testing.expectEqual(@as(usize, 1), ipv4.included_routes.len);
    try std.testing.expectEqualStrings(
        "10.8.12.0",
        ipv4.included_routes[0].destination.?.address.raw,
    );
    try std.testing.expectEqual(@as(u8, 24), ipv4.included_routes[0].destination.?.prefix_length);
    try std.testing.expectEqualStrings("10.8.12.1", configuration.route_gateway4.?.raw);

    const ipv6 = configuration.ipv6 orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), ipv6.subnets.len);
    try std.testing.expectEqualStrings("fd42:abcd:1234::9", ipv6.subnets[0].address.raw);
    try std.testing.expectEqual(@as(u8, 64), ipv6.subnets[0].prefix_length);
    try std.testing.expectEqual(@as(usize, 1), ipv6.included_routes.len);
    try std.testing.expectEqualStrings(
        "fd42:abcd:1234::",
        ipv6.included_routes[0].destination.?.address.raw,
    );
    try std.testing.expectEqual(@as(u8, 64), ipv6.included_routes[0].destination.?.prefix_length);
    try std.testing.expectEqualStrings("fd42:abcd:1234::1", configuration.route_gateway6.?.raw);
}

test "OpenVPNParser applies legacy net30 ifconfig semantics" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\ifconfig 10.8.0.6 10.8.0.5
        \\route-gateway 192.0.2.1
    );
    defer configuration.deinit(allocator);

    const ipv4 = configuration.ipv4 orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("10.8.0.6", ipv4.subnets[0].address.raw);
    try std.testing.expectEqual(@as(u8, 30), ipv4.subnets[0].prefix_length);
    try std.testing.expectEqualStrings(
        "10.8.0.4",
        ipv4.included_routes[0].destination.?.address.raw,
    );
    try std.testing.expectEqualStrings("10.8.0.5", configuration.route_gateway4.?.raw);
}

test "OpenVPNParser enforces Swift topology constraints" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.MalformedOption,
        OpenVPNParser.parse(
            allocator,
            "topology subnet\nifconfig 10.8.0.2 255.255.255.0",
        ),
    );
    try std.testing.expectError(
        error.UnsupportedConfiguration,
        OpenVPNParser.parse(
            allocator,
            "topology p2p\nifconfig 10.8.0.2 10.8.0.1",
        ),
    );
}

test "OpenVPNParser requires passphrase for encrypted client key" {
    const allocator = std.testing.allocator;
    const ovpn_parser = OpenVPNParser{ .decrypt_key = decryptKey };

    try std.testing.expectError(error.EmptyPassphrase, ovpn_parser.parseWithContext(allocator, encrypted_key_configuration, .{}));
    try std.testing.expectError(error.EmptyPassphrase, ovpn_parser.parseWithContext(allocator, encrypted_key_configuration, .{ .passphrase = "" }));
}

test "OpenVPNParser requires decrypter for encrypted client key" {
    const allocator = std.testing.allocator;
    const ovpn_parser = OpenVPNParser{};

    try std.testing.expectError(error.DecrypterRequired, ovpn_parser.parseWithContext(allocator, encrypted_key_configuration, .{ .passphrase = "secret" }));
}

test "OpenVPNParser reports decrypt failures for encrypted client key" {
    const allocator = std.testing.allocator;
    const ovpn_parser = OpenVPNParser{ .decrypt_key = failDecryptKey };

    try std.testing.expectError(error.UnableToDecrypt, ovpn_parser.parseWithContext(allocator, encrypted_key_configuration, .{ .passphrase = "secret" }));
}

test "OpenVPNParser decrypts encrypted client key" {
    const allocator = std.testing.allocator;
    const ovpn_parser = OpenVPNParser{ .decrypt_key = decryptKey };

    var configuration = try ovpn_parser.parseWithContext(allocator, encrypted_key_configuration, .{ .passphrase = "secret" });
    defer configuration.deinit(allocator);

    try std.testing.expectEqualStrings(decrypted_private_key, configuration.client_key.?.pem);
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

const decrypted_private_key =
    \\-----BEGIN PRIVATE KEY-----
    \\plain
    \\-----END PRIVATE KEY-----
;

fn decryptKey(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    pem: []const u8,
    passphrase: []const u8,
) ![]u8 {
    std.debug.assert(std.mem.eql(u8, "secret", passphrase));
    std.debug.assert(std.mem.indexOf(u8, pem, "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,0123456789ABCDEF\n\nciphertext") != null);
    return try allocator.dupe(u8, decrypted_private_key);
}

fn expectParseErrorInfo(
    expected_err: anytype,
    contents: []const u8,
    expected_name: []const u8,
    expected_details: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);

    try std.testing.expectError(
        expected_err,
        (OpenVPNParser{}).parseWithContext(allocator, contents, .{
            .parse_error_info = &info,
        }),
    );
    try std.testing.expectEqualStrings(expected_name, info.name);
    try std.testing.expectEqualStrings(expected_details, info.details);
}

fn failDecryptKey(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) ![]u8 {
    return error.DecryptionFailed;
}
