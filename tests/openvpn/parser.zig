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

test "OpenVPNParser parses TCP client protocol aliases" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\proto tcp-client
        \\remote default.example.com 443
        \\remote any.example.com 443 TCP-CLIENT
        \\remote ipv4.example.com 443 tcp4-client
        \\remote ipv6.example.com 443 TcP6-ClIeNt
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), configuration.remotes.?.len);
    try std.testing.expectEqual(api.IPSocketType.tcp, configuration.remotes.?[0].proto.socket_type);
    try std.testing.expectEqual(api.IPSocketType.tcp, configuration.remotes.?[1].proto.socket_type);
    try std.testing.expectEqual(api.IPSocketType.tcp4, configuration.remotes.?[2].proto.socket_type);
    try std.testing.expectEqual(api.IPSocketType.tcp6, configuration.remotes.?[3].proto.socket_type);
}

test "OpenVPNParser parses cipher and digest values case-insensitively" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\cipher aEs-256-cBc
        \\data-ciphers aes-256-gcm:AeS-128-GcM
        \\auth sHa256
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, configuration.cipher.?);
    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{ .aes256gcm, .aes128gcm },
        configuration.data_ciphers.?,
    );
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, configuration.digest.?);

    var fallback = try OpenVPNParser.parse(
        allocator,
        "data-ciphers-fallback aEs-192-CbC",
    );
    defer fallback.deinit(allocator);
    try std.testing.expectEqual(api.OpenVPNCipher.aes192cbc, fallback.cipher.?);

    var with_unsupported = try OpenVPNParser.parse(
        allocator,
        "data-ciphers CHACHA20-POLY1305:aes-256-gcm",
    );
    defer with_unsupported.deinit(allocator);
    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{.aes256gcm},
        with_unsupported.data_ciphers.?,
    );

    var unknown = try OpenVPNParser.parse(allocator,
        \\cipher UNKNOWN
        \\data-ciphers-fallback UNKNOWN
    );
    defer unknown.deinit(allocator);
    try std.testing.expect(unknown.cipher == null);
}

test "OpenVPNParser follows OpenVPN optional data cipher semantics" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(
        allocator,
        "data-ciphers ?AES-256-GCM:?CHACHA20-POLY1305:AES-128-GCM",
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{ .aes256gcm, .aes128gcm },
        configuration.data_ciphers.?,
    );

    var legacy_alias = try OpenVPNParser.parse(
        allocator,
        "ncp-ciphers AES-256-GCM:?CHACHA20-POLY1305",
    );
    defer legacy_alias.deinit(allocator);
    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{.aes256gcm},
        legacy_alias.data_ciphers.?,
    );

    var required_unknown = try OpenVPNParser.parse(
        allocator,
        "data-ciphers CHACHA20-POLY1305:AES-256-GCM",
    );
    defer required_unknown.deinit(allocator);
    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{.aes256gcm},
        required_unknown.data_ciphers.?,
    );

    var all_unknown = try OpenVPNParser.parse(
        allocator,
        "data-ciphers ?CHACHA20-POLY1305:?BF-CBC",
    );
    defer all_unknown.deinit(allocator);
    try std.testing.expect(all_unknown.data_ciphers == null);
}

test "OpenVPNParser gives explicit data cipher fallback order-independent precedence" {
    const allocator = std.testing.allocator;
    const profiles = [_][]const u8{
        "cipher AES-256-CBC\ndata-ciphers-fallback AES-128-CBC",
        "data-ciphers-fallback AES-128-CBC\ncipher AES-256-CBC",
    };
    for (profiles) |profile| {
        var configuration = try OpenVPNParser.parse(allocator, profile);
        defer configuration.deinit(allocator);
        try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, configuration.cipher.?);
    }
}

test "OpenVPNParser leaves client completeness to module import" {
    const allocator = std.testing.allocator;
    var without_ca = try OpenVPNParser.parse(
        allocator,
        "remote vpn.example.com 1194 udp",
    );
    defer without_ca.deinit(allocator);
    try std.testing.expect(without_ca.ca == null);
    try std.testing.expectEqual(@as(usize, 1), without_ca.remotes.?.len);

    var without_remote = try OpenVPNParser.parse(allocator,
        \\client
        \\<ca>
        \\-----BEGIN CERTIFICATE-----
        \\abc
        \\-----END CERTIFICATE-----
        \\</ca>
    );
    defer without_remote.deinit(allocator);
    try std.testing.expect(without_remote.ca != null);
    try std.testing.expect(without_remote.remotes == null);
}

test "OpenVPNParser rejects enabled LZO compression" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedCompression, OpenVPNParser.parse(allocator, "comp-lzo"));
    try std.testing.expectError(error.UnsupportedCompression, OpenVPNParser.parse(allocator, "compress lzo"));
}

test "OpenVPNParser treats keepalive as ping plus ping-restart" {
    const allocator = std.testing.allocator;
    var explicit = try OpenVPNParser.parse(
        allocator,
        "ping 10\nping-restart 60",
    );
    defer explicit.deinit(allocator);
    var shorthand = try OpenVPNParser.parse(allocator, "keepalive 10 60");
    defer shorthand.deinit(allocator);
    var different = try OpenVPNParser.parse(allocator, "keepalive 15 600");
    defer different.deinit(allocator);

    try std.testing.expectEqual(
        explicit.keep_alive_interval,
        shorthand.keep_alive_interval,
    );
    try std.testing.expectEqual(
        explicit.keep_alive_timeout,
        shorthand.keep_alive_timeout,
    );
    try std.testing.expect(explicit.keep_alive_interval != different.keep_alive_interval);
    try std.testing.expect(explicit.keep_alive_timeout != different.keep_alive_timeout);
}

test "OpenVPNParser parses DHCP DNS, domains, and proxy options" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\dhcp-option DNS 8.8.8.8
        \\dhcp-option DNS6 ffff::1
        \\dhcp-option DOMAIN first-domain.net
        \\dhcp-option DOMAIN second-domain.org
        \\dhcp-option DOMAIN-SEARCH one.com
        \\dhcp-option DOMAIN-SEARCH two.com
        \\dhcp-option PROXY_HTTP 1.2.3.4 8081
        \\dhcp-option PROXY_HTTPS 7.8.9.10 8082
        \\dhcp-option PROXY_AUTO_CONFIG_URL https://pac/
        \\dhcp-option PROXY_BYPASS foo.com bar.org net.chat
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), configuration.dns_servers.?.len);
    try std.testing.expectEqualStrings("8.8.8.8", configuration.dns_servers.?[0]);
    try std.testing.expectEqualStrings("ffff::1", configuration.dns_servers.?[1]);
    try std.testing.expectEqualStrings("second-domain.org", configuration.dns_domain.?);
    try std.testing.expectEqual(@as(usize, 2), configuration.search_domains.?.len);
    try std.testing.expectEqualStrings("one.com", configuration.search_domains.?[0]);
    try std.testing.expectEqualStrings("1.2.3.4", configuration.http_proxy.?.address);
    try std.testing.expectEqual(@as(u16, 8081), configuration.http_proxy.?.port);
    try std.testing.expectEqualStrings("7.8.9.10", configuration.https_proxy.?.address);
    try std.testing.expectEqualStrings(
        "https://pac/",
        configuration.proxy_auto_configuration_url.?,
    );
    try std.testing.expectEqual(@as(usize, 3), configuration.proxy_bypass_domains.?.len);
}

test "OpenVPNParser stores scramble masks as UTF-8 SecureData" {
    const allocator = std.testing.allocator;
    var xormask = try OpenVPNParser.parse(allocator, "scramble xormask F");
    defer xormask.deinit(allocator);
    const single_mask = switch (xormask.xor_method.?) {
        .xormask => |value| value.mask,
        else => return error.TestUnexpectedResult,
    };
    const single_bytes = try single_mask.bytesAlloc(allocator);
    defer allocator.free(single_bytes);
    try std.testing.expectEqualStrings("F", single_bytes);

    var xorptrpos = try OpenVPNParser.parse(allocator, "scramble xorptrpos");
    defer xorptrpos.deinit(allocator);
    try std.testing.expect(xorptrpos.xor_method.? == .xorptrpos);

    var reverse = try OpenVPNParser.parse(allocator, "scramble reverse");
    defer reverse.deinit(allocator);
    try std.testing.expect(reverse.xor_method.? == .reverse);

    var obfuscate = try OpenVPNParser.parse(allocator, "scramble obfuscate FFFF");
    defer obfuscate.deinit(allocator);
    const mask = switch (obfuscate.xor_method.?) {
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

test "OpenVPNParser rejects connection blocks" {
    try std.testing.expectError(
        error.UnsupportedConfiguration,
        OpenVPNParser.parse(
            std.testing.allocator,
            "<connection>\n</connection>",
        ),
    );
}

test "OpenVPNParser rejects embedded and external auth-user-pass credentials" {
    try std.testing.expectError(
        error.UnsupportedConfiguration,
        OpenVPNParser.parse(
            std.testing.allocator,
            "<auth-user-pass>\nusername\npassword\n</auth-user-pass>",
        ),
    );
    try std.testing.expectError(
        error.UnsupportedConfiguration,
        OpenVPNParser.parse(
            std.testing.allocator,
            "auth-user-pass credentials.txt",
        ),
    );
}

test "OpenVPNParser parses tls-crypt-v2 static and wrapped keys" {
    const allocator = std.testing.allocator;
    var combined: [260]u8 = undefined;
    for (combined[0..256], 0..) |*byte, index| byte.* = @truncate(index);
    const wrapped_bytes = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    @memcpy(combined[256..], &wrapped_bytes);
    var encoded = try api.SecureData.initBytesAlloc(allocator, &combined);
    defer encoded.deinit(allocator);
    const contents = try std.fmt.allocPrint(
        allocator,
        "tls-crypt-v2 [inline]\n<tls-crypt-v2>\n-----BEGIN OpenVPN tls-crypt-v2 client key-----\n{s}\n-----END OpenVPN tls-crypt-v2 client key-----\n</tls-crypt-v2>",
        .{encoded.base64},
    );
    defer allocator.free(contents);
    var configuration = try OpenVPNParser.parse(allocator, contents);
    defer configuration.deinit(allocator);
    const wrap = configuration.tls_wrap orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.OpenVPNTLSWrapStrategy.cryptV2, wrap.strategy);
    try std.testing.expectEqual(
        api.OpenVPNStaticKeyDirection.client,
        wrap.key.dir.?,
    );
    const key = try wrap.key.data.bytesAlloc(allocator);
    defer allocator.free(key);
    try std.testing.expectEqualSlices(u8, combined[0..256], key);
    const wrapped = try wrap.wrapped_key.?.bytesAlloc(allocator);
    defer allocator.free(wrapped);
    try std.testing.expectEqualSlices(u8, combined[256..], wrapped);
}

test "OpenVPNParser requires inline blocks for bare TLS wrap directives" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedOption,
        OpenVPNParser.parse(allocator, "tls-auth"),
    );
    try std.testing.expectError(
        error.MalformedOption,
        OpenVPNParser.parse(allocator, "tls-crypt"),
    );
    try std.testing.expectError(
        error.MalformedOption,
        OpenVPNParser.parse(allocator, "tls-crypt-v2"),
    );

    var key_hex: [512]u8 = undefined;
    @memset(&key_hex, '0');
    const contents = try std.fmt.allocPrint(
        allocator,
        "client\n<tls-auth>\n-----BEGIN OpenVPN Static key V1-----\n{s}\n-----END OpenVPN Static key V1-----\n</tls-auth>",
        .{&key_hex},
    );
    defer allocator.free(contents);
    var configuration = try OpenVPNParser.parse(allocator, contents);
    defer configuration.deinit(allocator);
    try std.testing.expectEqual(
        api.OpenVPNTLSWrapStrategy.auth,
        configuration.tls_wrap.?.strategy,
    );
    try std.testing.expect(configuration.tls_wrap.?.key.dir == null);
}

test "OpenVPNParser ignores incomplete route and gateway directives" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(
        allocator,
        "route\nroute-ipv6\nroute-gateway\nroute-ipv6-gateway",
    );
    defer configuration.deinit(allocator);
    try std.testing.expect(configuration.routes4 == null);
    try std.testing.expect(configuration.routes6 == null);
    try std.testing.expect(configuration.route_gateway4 == null);
    try std.testing.expect(configuration.route_gateway6 == null);
}

test "OpenVPNParser ignores optional values Swift cannot convert" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator,
        \\compress stub trailing
        \\key-direction 2
        \\port 99999
        \\remote vpn.example.com
        \\tun-mtu 999999999999999999999
        \\peer-id 999999999999999999999
        \\route 192.0.2.0 255.255.255.0 net_gateway
        \\route-ipv6 2001:db8::/64 net_gateway
        \\route-gateway dhcp trailing
        \\route-ipv6-gateway net_gateway
        \\dhcp-option PROXY_HTTP proxy.example 99999
    );
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(
        api.OpenVPNCompressionAlgorithm.disabled,
        configuration.compression_algorithm.?,
    );
    try std.testing.expectEqual(@as(u16, 1194), configuration.remotes.?[0].proto.port);
    try std.testing.expect(configuration.mtu == null);
    try std.testing.expect(configuration.peer_id == null);
    try std.testing.expect(configuration.route_gateway4 == null);
    try std.testing.expect(configuration.route_gateway6 == null);
    try std.testing.expect(configuration.http_proxy == null);
    try std.testing.expectEqual(@as(usize, 1), configuration.routes4.?.len);
    try std.testing.expect(configuration.routes4.?[0].gateway == null);
    try std.testing.expectEqual(@as(usize, 1), configuration.routes6.?.len);
    try std.testing.expect(configuration.routes6.?[0].gateway == null);
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

test "OpenVPNParser parses the PIA profile fixture" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator, pia_hungary);
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), configuration.remotes.?.len);
    try std.testing.expectEqualStrings(
        "hungary.privateinternetaccess.com",
        configuration.remotes.?[0].address,
    );
    try std.testing.expectEqual(api.IPSocketType.udp, configuration.remotes.?[0].proto.socket_type);
    try std.testing.expectEqual(@as(u16, 1198), configuration.remotes.?[0].proto.port);
    try std.testing.expectEqual(api.IPSocketType.tcp, configuration.remotes.?[1].proto.socket_type);
    try std.testing.expectEqual(@as(u16, 502), configuration.remotes.?[1].proto.port);
    try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, configuration.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha1, configuration.digest.?);
    try std.testing.expectEqual(true, configuration.auth_user_pass.?);
    try std.testing.expectEqual(
        api.OpenVPNCompressionAlgorithm.disabled,
        configuration.compression_algorithm.?,
    );
    try std.testing.expectEqual(@as(?f64, 0), configuration.renegotiates_after);
    try std.testing.expect(std.mem.startsWith(
        u8,
        configuration.ca.?.pem,
        "-----BEGIN CERTIFICATE-----",
    ));
}

test "OpenVPNParser parses the ProtonVPN profile fixture" {
    const allocator = std.testing.allocator;
    var configuration = try OpenVPNParser.parse(allocator, protonvpn);
    defer configuration.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), configuration.remotes.?.len);
    try std.testing.expectEqualStrings(
        "103.212.227.123",
        configuration.remotes.?[0].address,
    );
    try std.testing.expectEqual(@as(u16, 5060), configuration.remotes.?[0].proto.port);
    try std.testing.expectEqual(@as(u16, 80), configuration.remotes.?[4].proto.port);
    try std.testing.expectEqual(true, configuration.randomize_endpoint.?);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, configuration.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha512, configuration.digest.?);
    try std.testing.expectEqual(@as(?f64, 0), configuration.renegotiates_after);
    try std.testing.expectEqual(true, configuration.auth_user_pass.?);
    const mask = switch (configuration.xor_method.?) {
        .obfuscate => |value| try value.mask.bytesAlloc(allocator),
        else => return error.TestUnexpectedResult,
    };
    defer allocator.free(mask);
    try std.testing.expectEqualStrings("this-is-a-mask", mask);
    try std.testing.expectEqual(
        api.OpenVPNTLSWrapStrategy.auth,
        configuration.tls_wrap.?.strategy,
    );
    try std.testing.expectEqual(
        api.OpenVPNStaticKeyDirection.client,
        configuration.tls_wrap.?.key.dir.?,
    );
    const key_hex = try configuration.tls_wrap.?.key.data.hexAlloc(allocator);
    defer allocator.free(key_hex);
    try std.testing.expect(std.mem.startsWith(
        u8,
        key_hex,
        "6acef03f62675b4b1bbd03e53b187727",
    ));
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

test "OpenVPNParser creates a decrypter from its default crypto backend" {
    const allocator = std.testing.allocator;
    const ovpn_parser = OpenVPNParser.init(null);

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

const pia_hungary = @embedFile("fixtures/pia-hungary.ovpn");
const protonvpn = @embedFile("fixtures/protonvpn.ovpn");

fn decryptKey(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    pem: []const u8,
    passphrase: []const u8,
) ![]u8 {
    if (!std.mem.eql(u8, "secret", passphrase))
        return error.DecryptionFailed;
    if (std.mem.indexOf(u8, pem, "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,0123456789ABCDEF\n\nciphertext") == null)
        return error.DecryptionFailed;
    return try allocator.dupe(u8, decrypted_private_key);
}

fn expectParseErrorInfo(
    expected_err: anytype,
    contents: []const u8,
    expected_name: []const u8,
    expected_line: []const u8,
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
    try std.testing.expectEqualStrings(expected_name, info.name.?);
    try std.testing.expectEqualStrings(expected_line, info.line.?);
    try std.testing.expectEqual(@as(usize, 0), info.arguments.len);
}

fn failDecryptKey(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) ![]u8 {
    return error.DecryptionFailed;
}
