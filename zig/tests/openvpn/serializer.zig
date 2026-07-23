// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");

const api = source.core.api;
const Parser = source.openvpn_parser.Parser;
const serializer = source.openvpn_serializer;

test "OpenVPN serializer generates client configuration" {
    const allocator = std.testing.allocator;
    var mask = try api.SecureData.initBytesAlloc(allocator, "secret");
    defer mask.deinit(allocator);

    const configuration = api.OpenVPNConfiguration{
        .cipher = .aes256cbc,
        .data_ciphers = &.{ .aes256gcm, .aes128gcm },
        .digest = .sha256,
        .compression_framing = .compressV2,
        .compression_algorithm = .LZO,
        .ca = .{ .pem = "-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----" },
        .client_certificate = .{ .pem = "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----" },
        .client_key = .{ .pem = "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----" },
        .keep_alive_interval = 10.4,
        .keep_alive_timeout = 60.5,
        .renegotiates_after = 3600.5,
        .remotes = &.{
            api.ExtendedEndpoint.init("vpn.example.com", .init(.udp, 1194)).?,
            api.ExtendedEndpoint.init("2001:db8::1", .init(.tcp6, 443)).?,
        },
        .checks_eku = true,
        .checks_san_host = true,
        .san_host = "vpn.example.com",
        .randomize_endpoint = true,
        .randomize_hostnames = true,
        .mtu = 1400,
        .auth_user_pass = true,
        .auth_token = "token",
        .peer_id = 77,
        .routes4 = &.{.{
            .destination = api.Subnet.parseRaw("10.20.0.0/16").?,
            .gateway = api.Address.parseRaw("10.8.0.1").?,
        }},
        .routes6 = &.{.{
            .destination = api.Subnet.parseRaw("2001:db8:20::/48").?,
            .gateway = api.Address.parseRaw("2001:db8::1").?,
        }},
        .route_gateway4 = api.Address.parseRaw("10.8.0.1").?,
        .route_gateway6 = api.Address.parseRaw("2001:db8::1").?,
        .dns_servers = &.{ "1.1.1.1", "2001:4860:4860::8888" },
        .dns_domain = "example.org",
        .search_domains = &.{ "example.org", "vpn.example.org" },
        .http_proxy = .{ .address = "192.0.2.1", .port = 8080 },
        .https_proxy = .{ .address = "192.0.2.2", .port = 8443 },
        .proxy_auto_configuration_url = "https://pac.example.org/proxy.pac",
        .proxy_bypass_domains = &.{ "localhost", "internal.example.org" },
        .routing_policies = &.{ .IPv6, .blockLocal },
        .no_pull_mask = &.{ .dns, .proxy },
        .xor_method = .{ .obfuscate = .{ .mask = mask } },
    };

    const serialized = try serializer.serializeConfiguration(allocator, &configuration);
    defer allocator.free(serialized);

    try std.testing.expectEqualStrings(
        \\client
        \\dev tun
        \\nobind
        \\persist-key
        \\persist-tun
        \\data-ciphers AES-256-GCM:AES-128-GCM
        \\data-ciphers-fallback AES-256-CBC
        \\auth SHA256
        \\compress stub-v2
        \\keepalive 10 61
        \\reneg-sec 3601
        \\remote-cert-tls server
        \\verify-x509-name vpn.example.com name
        \\remote-random
        \\remote-random-hostname
        \\tun-mtu 1400
        \\remote vpn.example.com 1194 udp
        \\remote 2001:db8::1 443 tcp6
        \\auth-user-pass
        \\auth-token token
        \\peer-id 77
        \\redirect-gateway !ipv4 ipv6 block-local
        \\route-gateway 10.8.0.1
        \\route-ipv6-gateway 2001:db8::1
        \\dhcp-option DNS 1.1.1.1
        \\dhcp-option DNS 2001:4860:4860::8888
        \\dhcp-option DOMAIN example.org
        \\dhcp-option DOMAIN-SEARCH example.org
        \\dhcp-option DOMAIN-SEARCH vpn.example.org
        \\dhcp-option PROXY_HTTP 192.0.2.1 8080
        \\dhcp-option PROXY_HTTPS 192.0.2.2 8443
        \\dhcp-option PROXY_AUTO_CONFIG_URL https://pac.example.org/proxy.pac
        \\dhcp-option PROXY_BYPASS localhost internal.example.org
        \\route 10.20.0.0 255.255.0.0 10.8.0.1
        \\route-ipv6 2001:db8:20::/48 2001:db8::1
        \\scramble obfuscate secret
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\CA
        \\-----END CERTIFICATE-----
        \\</ca>
        \\<cert>
        \\-----BEGIN CERTIFICATE-----
        \\CERT
        \\-----END CERTIFICATE-----
        \\</cert>
        \\<key>
        \\-----BEGIN PRIVATE KEY-----
        \\KEY
        \\-----END PRIVATE KEY-----
        \\</key>
    , serialized);
}

test "OpenVPN module export serializes module configuration" {
    const allocator = std.testing.allocator;
    var configuration = try Parser.parse(allocator,
        \\client
        \\remote vpn.example.com 1194 udp
        \\auth-user-pass
    );
    defer configuration.deinit(allocator);

    const module = api.TaggedModule{ .OpenVPN = .{ .configuration = configuration } };
    const serialized = try source.openvpn_exports.impl.module.serializeModule(allocator, &module, null);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.startsWith(u8, serialized, "client\ndev tun\nnobind\npersist-key\npersist-tun\n"));
    try std.testing.expect(std.mem.indexOf(u8, serialized, "remote vpn.example.com 1194 udp") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "auth-user-pass") != null);
}

test "OpenVPN serializer preserves legacy directive variants" {
    const allocator = std.testing.allocator;
    const serialized = try serializer.serializeConfiguration(allocator, &.{
        .cipher = .aes128cbc,
        .compression_framing = .compLZO,
        .compression_algorithm = .disabled,
        .keep_alive_interval = 12,
        .routing_policies = &.{.IPv4},
    });
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "cipher AES-128-CBC") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "data-ciphers-fallback") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "comp-lzo no") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "ping 12") != null);
    try std.testing.expect(std.mem.endsWith(u8, serialized, "redirect-gateway"));
}

test "OpenVPN serializer round-trips static TLS keys through core SecureData" {
    const allocator = std.testing.allocator;
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var key_data = try api.SecureData.initBytesAlloc(allocator, &bytes);
    defer key_data.deinit(allocator);

    const configuration = api.OpenVPNConfiguration{
        .tls_wrap = .{
            .strategy = .auth,
            .key = .{ .data = key_data, .dir = .client },
        },
    };
    const serialized = try serializer.serializeConfiguration(allocator, &configuration);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "key-direction 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<tls-auth>\n# 2048 bit OpenVPN static key") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "000102030405060708090a0b0c0d0e0f") != null);

    var reparsed = try Parser.parse(allocator, serialized);
    defer reparsed.deinit(allocator);
    const reparsed_bytes = try reparsed.tls_wrap.?.key.data.bytesAlloc(allocator);
    defer allocator.free(reparsed_bytes);
    try std.testing.expectEqualSlices(u8, &bytes, reparsed_bytes);
    try std.testing.expectEqual(api.OpenVPNStaticKeyDirection.client, reparsed.tls_wrap.?.key.dir.?);
}

test "OpenVPN serializer round-trips tls-crypt-v2 keys" {
    const allocator = std.testing.allocator;
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var key_data = try api.SecureData.initBytesAlloc(allocator, &bytes);
    defer key_data.deinit(allocator);
    var wrapped_key = try api.SecureData.initBytesAlloc(allocator, &.{ 0xaa, 0xbb, 0xcc, 0xdd });
    defer wrapped_key.deinit(allocator);

    const configuration = api.OpenVPNConfiguration{
        .tls_wrap = .{
            .strategy = .cryptV2,
            .key = .{ .data = key_data, .dir = .client },
            .wrapped_key = wrapped_key,
        },
    };
    const serialized = try serializer.serializeConfiguration(allocator, &configuration);
    defer allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<tls-crypt-v2>\n-----BEGIN OpenVPN tls-crypt-v2 client key-----") != null);

    var reparsed = try Parser.parse(allocator, serialized);
    defer reparsed.deinit(allocator);
    const reparsed_key = try reparsed.tls_wrap.?.key.data.bytesAlloc(allocator);
    defer allocator.free(reparsed_key);
    const reparsed_wrapped = try reparsed.tls_wrap.?.wrapped_key.?.bytesAlloc(allocator);
    defer allocator.free(reparsed_wrapped);
    try std.testing.expectEqualSlices(u8, &bytes, reparsed_key);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, reparsed_wrapped);
}

test "OpenVPN serializer rejects unsupported static challenge and invalid masks" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.SerializationFailed,
        serializer.serializeConfiguration(allocator, &.{ .static_challenge = true }),
    );

    var invalid_utf8 = try api.SecureData.initBytesAlloc(allocator, &.{0xff});
    defer invalid_utf8.deinit(allocator);
    try std.testing.expectError(
        error.SerializationFailed,
        serializer.serializeConfiguration(allocator, &.{
            .xor_method = .{ .xormask = .{ .mask = invalid_utf8 } },
        }),
    );
}
