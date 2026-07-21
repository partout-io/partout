// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");
const api = source.core_api;
const util = source.core.util;

test "parses IPv4 addresses" {
    try expectAddress("1.2.3.4", .v4);
    try expectAddress("0.0.0.0", .v4);
    try expectAddress("255.255.255.255", .v4);
    try expectAddress(" 1.2.3.4 ", .v4);
    try expectAddressNotIP("-1.2.3.4");
    try expectAddressNotIP("1#2.3.4");
    try expectAddressNotIP("1.2.3.4.5");
    try expectAddressNotIP("256.255.255.255");
}

test "parses IPv6 addresses" {
    try expectAddress("2607:f0d0:1002:51::4", .v6);
    try expectAddress("::4", .v6);
    try expectAddress("2607:f0d0:1002:51:ffff:5435:4550:4", .v6);
    try expectAddress("  ::4  ", .v6);
    try expectAddress("::", .v6);
    try expectAddressNotIP("2607:f0d0:1002:51:ffff:5435:4550:4:44");
    try expectAddressNotIP(":1");
    try expectAddressNotIP("g607:f0d0:1002:51::4");
}

test "parses hostnames as addresses" {
    try expectAddress("foobar", .hostname);
    try expectAddress("    ,", .hostname);
}

test "rejects empty addresses and keeps malformed IPs as hostnames" {
    try std.testing.expect(api.Address.parseRaw("") == null);
    try std.testing.expect(api.Address.parseRaw("    ") == null);
    try expectAddressNotIP(":%:");
    try expectAddressNotIP(":%:11");
    try expectAddressNotIP(".");
}

test "propagates owned address parser OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        api.Address.parseValue(failing.allocator(), .{ .string = "1.2.3.4" }),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "reports generated JSON error keys" {
    const allocator = std.testing.allocator;

    var info: api.JsonErrorInfo = .{};
    try std.testing.expectError(
        error.InvalidModel,
        api.WireGuardModule.parseWithErrorInfo(allocator,
            \\{"id":"00000000-0000-0000-0000-000000000100","configuration":{"interface":{"privateKey":"not base64","addresses":[]},"peers":[]}}
        , &info),
    );
    try std.testing.expectEqualStrings("privateKey", info.key orelse return error.TestUnexpectedResult);

    // ZIGME: Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    // info.key = "stale";
    // try std.testing.expectError(
    //     error.InvalidModel,
    //     api.WireGuardModule.parseWithErrorInfo(allocator,
    //         \\{"id":"00000000-0000-0000-0000-000000000100"}
    //     , &info),
    // );
    // try std.testing.expectEqualStrings("configuration", info.key orelse return error.TestUnexpectedResult);

    info.key = "stale";
    try std.testing.expectError(
        error.UnsupportedModel,
        api.TaggedModule.parseWithErrorInfo(allocator,
            \\{"type":"Bogus","value":{}}
        , &info),
    );
    try std.testing.expectEqualStrings("type", info.key orelse return error.TestUnexpectedResult);
}

test "computes IPv4 networks" {
    try expectNetworkRaw("1.2.3.4/0", "0.0.0.0/0");
    try expectNetworkRaw("1.2.3.4/16", "1.2.0.0/16");
    try expectNetworkRaw("1.2.3.4/24", "1.2.3.0/24");
    try expectNetworkRaw("1.2.3.4/32", "1.2.3.4/32");
}

test "computes IPv6 networks" {
    try expectNetworkRaw("2f:2:33::4/0", "::/0");
    try expectNetworkRaw("2f:2:33::4/5", "::/5");
    try expectNetworkRaw("2f:2:33::4/16", "2f::/16");
    try expectNetworkRaw("2f:2:33::4/24", "2f::/24");
    try expectNetworkRaw("2f:2:33::4/30", "2f::/30");
    try expectNetworkRaw("2f:2:33::4/32", "2f:2::/32");
    try expectNetworkRaw("2f:2:33::4/43", "2f:2:20::/43");
    try expectNetworkRaw("2f:2:33::4/47", "2f:2:32::/47");
    try expectNetworkRaw("2f:2:33::4/48", "2f:2:33::/48");
    try expectNetworkRaw("2f:2:33::4/128", "2f:2:33::4/128");
}

test "parses IPv4 endpoints" {
    try expectEndpoint("1.2.3.4:1194", "1.2.3.4", 1194, .v4);
    try expectEndpointFailure("1.2.3:1194", .v4);
    try expectEndpointFailure("1.2.3.4.5:1194", .v4);
}

test "parses IPv6 endpoints" {
    try expectEndpoint("2607:f0d0:1002:51::4:1194", "2607:f0d0:1002:51::4", 1194, .v6);
    try expectEndpoint("4:::1194", "4::", 1194, .v6);
    try expectEndpointFailure("::4:::1194", .v6);
}

test "parses bracketed IPv6 endpoints" {
    const endpoint = api.Endpoint.parseRaw("[2607:f0d0:1002:51::4]:1194") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2607:f0d0:1002:51::4", endpoint.address);
    try std.testing.expectEqual(api.Address.Family.v6, endpointFamily(endpoint));
    try std.testing.expectEqual(@as(u16, 1194), endpoint.port);
}

test "parses IPv4 extended endpoints" {
    try expectExtendedEndpoint("1.2.3.4:TCP:1194", "1.2.3.4", .tcp, 1194, .v4);
    try expectExtendedEndpoint("1.2.3.4:UDP6:1194", "1.2.3.4", .udp6, 1194, .v4);
    try expectExtendedEndpoint("1.2.3.4:TCP6:1194", "1.2.3.4", .tcp6, 1194, .v4);
    try expectExtendedEndpointFailure("1.2.3.4.5:TCP:1194", .v4);
    try expectExtendedEndpointFailure("1.2.3.4:TCP5:1194", .v4);
}

test "parses IPv6 extended endpoints" {
    try expectExtendedEndpoint("2607:f0d0:1002:51::4:TCP:1194", "2607:f0d0:1002:51::4", .tcp, 1194, .v6);
    try expectExtendedEndpoint("2607:f0d0:1002:51::4:TCP4:1194", "2607:f0d0:1002:51::4", .tcp4, 1194, .v6);
    try expectExtendedEndpoint("2607:f0d0:1002:51::4:UDP6:1194", "2607:f0d0:1002:51::4", .udp6, 1194, .v6);
    try expectExtendedEndpointFailure("::4::UDP6:1194", .v6);
    try expectExtendedEndpointFailure("::4:UDP7:1194", .v6);
}

test "formats extended endpoints and infers plain socket type" {
    const endpoint = api.ExtendedEndpoint.parseRaw("vpn.example.com:UDP:1194") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("vpn.example.com", endpoint.address);
    try std.testing.expectEqual(api.IPSocketType.udp, endpoint.proto.socket_type);
    try std.testing.expectEqual(@as(u16, 1194), endpoint.proto.port);
    try std.testing.expectEqual(api.SocketType.udp, endpoint.plainSocketType());

    const raw = try endpoint.rawAlloc(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("vpn.example.com:UDP:1194", raw);
}

test "parses endpoint protocols" {
    const proto = api.EndpointProtocol.parseRaw("UDP4:1194") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.IPSocketType.udp4, proto.socket_type);
    try std.testing.expectEqual(@as(u16, 1194), proto.port);

    const raw = try proto.rawAlloc(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("UDP4:1194", raw);

    try std.testing.expect(api.EndpointProtocol.parseRaw("UDP:1194:extra") == null);
}

test "parses IPv4 subnets" {
    try expectSubnet("1.2.3.4/0", "1.2.3.4", 0, .v4);
    try expectSubnet("1.2.3.4/16", "1.2.3.4", 16, .v4);
    try expectSubnet("1.2.3.4/32", "1.2.3.4", 32, .v4);
    try expectSubnetFailure("1.2.3/16", .v4);
    try expectSubnetFailure("1.2.3.4.5/16", .v4);
}

test "parses IPv6 subnets" {
    try expectSubnet("2607:f0d0:1002:51::4/0", "2607:f0d0:1002:51::4", 0, .v6);
    try expectSubnet("2607:f0d0:1002:51::4/48", "2607:f0d0:1002:51::4", 48, .v6);
    try expectSubnet("2607:f0d0:1002:51::4/128", "2607:f0d0:1002:51::4", 128, .v6);
    try expectSubnet("4::/72", "4::", 72, .v6);
    try expectSubnetFailure("::4::/72", .v6);
}

test "formats subnet network addresses" {
    try expectNetworkRaw("192.168.12.34/24", "192.168.12.0/24");
    try expectNetworkRaw("2001:db8:abcd:1234::1/64", "2001:db8:abcd:1234::/64");
}

test "round-trips secure data" {
    try expectRoundTrip(api.SecureData, "\"MTIzNDU2\"");
    try std.testing.expect(api.SecureData.parseRaw("not base64") == null);
}

test "round-trips single-string API values" {
    try expectRoundTrip(api.Address, "\"203.0.113.5\"");
    try expectRoundTrip(api.Address, "\"2001:db8::5\"");
    try expectRoundTrip(api.Address, "\"vpn.example.com\"");
    try expectRoundTrip(api.Subnet, "\"10.10.0.8/24\"");
    try expectRoundTrip(api.Subnet, "\"2001:db8:1::8/64\"");
    try expectRoundTrip(api.Endpoint, "\"198.51.100.10:443\"");
    try expectRoundTrip(api.EndpointProtocol, "\"TCP6:8443\"");
    try expectRoundTrip(api.ExtendedEndpoint, "\"vpn.example.com:UDP4:1194\"");
    try expectRoundTrip(api.ExtendedEndpoint, "\"2001:db8::20:TCP6:443\"");
    try expectRoundTrip(api.WireGuardKey, "\"" ++ key_01 ++ "\"");
    try expectRoundTrip(api.SecureData, "\"3q2+7w==\"");

    const crypto = api.OpenVPNCryptoContainer.parseRaw("ignored preamble\n" ++ certificate_pem);
    try std.testing.expectEqualStrings(certificate_pem, crypto.pem);
    try expectRoundTrip(api.OpenVPNCryptoContainer, "\"" ++ certificate_pem_json ++ "\"");
}

test "rejects malformed single-string API values" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidModel, parseFromJson(api.Subnet, allocator, "\"vpn.example.com/24\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.Endpoint, allocator, "\"198.51.100.10:not-a-port\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.EndpointProtocol, allocator, "\"SCTP:1194\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.ExtendedEndpoint, allocator, "\"vpn.example.com:ICMP:0\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.WireGuardKey, allocator, "\"not base64\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.SecureData, allocator, "\"not base64\""));

    var malformed_crypto = try parseFromJson(api.OpenVPNCryptoContainer, allocator, "\"not a pem\"");
    defer malformed_crypto.deinit(allocator);
    try std.testing.expectEqualStrings("", malformed_crypto.pem);
}

test "decodes explicit nulls as absent optional API fields" {
    const allocator = std.testing.allocator;

    var profile = try parseFromJson(api.Profile, allocator,
        \\{"version":null,"id":"00000000-0000-0000-0000-000000000108","name":"Nulls","modules":[],"activeModulesIds":[],"behavior":null,"userInfo":null}
    );
    defer profile.deinit(allocator);
    try std.testing.expect(profile.version == null);
    try std.testing.expect(profile.behavior == null);
    try std.testing.expect(profile.user_info == null);

    var configuration = try parseFromJson(api.OpenVPNConfiguration, allocator,
        \\{"cipher":null,"dataCiphers":null,"tlsWrap":null,"keepAliveInterval":null,"sanHost":null,"ipv4":null,"xorMethod":null}
    );
    defer configuration.deinit(allocator);
    try std.testing.expect(configuration.cipher == null);
    try std.testing.expect(configuration.data_ciphers == null);
    try std.testing.expect(configuration.tls_wrap == null);
    try std.testing.expect(configuration.keep_alive_interval == null);
    try std.testing.expect(configuration.san_host == null);
    try std.testing.expect(configuration.ipv4 == null);
    try std.testing.expect(configuration.xor_method == null);

    var module = try parseFromJson(api.OpenVPNModule, allocator,
        \\{"id":"00000000-0000-0000-0000-000000000109","configuration":{},"credentials":null,"requiresInteractiveCredentials":null}
    );
    defer module.deinit(allocator);
    try std.testing.expect(module.credentials == null);
    try std.testing.expect(module.requires_interactive_credentials == null);
}

test "round-trips core API structs" {
    try expectRoundTrip(api.Route,
        \\{"destination":"172.16.0.0/12","gateway":"10.10.0.1"}
    );
    try expectRoundTrip(api.IPSettings,
        \\{"subnets":["10.10.0.8/24"],"includedRoutes":[{"destination":"172.16.0.0/12","gateway":"10.10.0.1"}],"excludedRoutes":[{"destination":"192.168.0.0/16"}]}
    );
    try expectRoundTrip(api.ProfileBehavior,
        \\{"disconnectsOnSleep":true,"includesAllNetworks":true}
    );
    try expectRoundTrip(api.DataCount,
        \\{"received":12345,"sent":67890}
    );
    try expectRoundTrip(api.TunnelSnapshotEnvironment,
        \\{"connectionStatus":"connected","dataCount":{"received":1024,"sent":2048},"lastErrorCode":"test.error"}
    );
    try expectRoundTrip(api.TunnelSnapshot,
        \\{"id":"00000000-0000-0000-0000-000000000100","isEnabled":true,"status":"active","onDemand":true,"environment":{"connectionStatus":"connecting","dataCount":{"received":3,"sent":4},"lastErrorCode":"last.error"}}
    );
}

test "round-trips DNS protocol tags" {
    try expectRoundTrip(api.DNSModuleProtocolType,
        \\{"type":"cleartext"}
    );
    try expectRoundTrip(api.DNSModuleProtocolType,
        \\{"type":"https","url":"https://dns.example.com/query"}
    );
    try expectRoundTrip(api.DNSModuleProtocolType,
        \\{"type":"tls","hostname":"dns.example.com"}
    );

    const encoded_https = try encodedFromJson(api.DNSModuleProtocolType,
        \\{"type":"https","url":"https://dns.example.com/query"}
    );
    defer std.testing.allocator.free(encoded_https);
    try expectJsonContains(encoded_https, "\"type\":\"https\"");

    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.DNSModuleProtocolType, allocator,
        \\{"type":"https","hostname":"dns.example.com"}
    ));
    try std.testing.expectError(error.UnsupportedModel, parseFromJson(api.DNSModuleProtocolType, allocator,
        \\{"type":"bogus"}
    ));
}

test "round-trips OpenVPN obfuscation tags" {
    try expectRoundTrip(api.OpenVPNObfuscationMethod,
        \\{"type":"xormask","mask":"AQID"}
    );
    try expectRoundTrip(api.OpenVPNObfuscationMethod,
        \\{"type":"xorptrpos"}
    );
    try expectRoundTrip(api.OpenVPNObfuscationMethod,
        \\{"type":"reverse"}
    );
    try expectRoundTrip(api.OpenVPNObfuscationMethod,
        \\{"type":"obfuscate","mask":"BAUG"}
    );

    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.OpenVPNObfuscationMethod, allocator,
        \\{"type":"xormask"}
    ));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.OpenVPNObfuscationMethod, allocator,
        \\{"type":"obfuscate"}
    ));
    try std.testing.expectError(error.UnsupportedModel, parseFromJson(api.OpenVPNObfuscationMethod, allocator,
        \\{"type":"bogus"}
    ));
}

test "round-trips OpenVPN credentials" {
    try expectRoundTrip(api.OpenVPNCredentials,
        \\{"username":"user","password":"password","otpMethod":"append","otp":"123456"}
    );
    try expectRoundTrip(api.OpenVPNCredentials,
        \\{"username":"user","password":"password","otpMethod":"none"}
    );

    const allocator = std.testing.allocator;
    try std.testing.expectEqual(api.OpenVPNCredentialsOTPMethod.none, try parseFromJson(api.OpenVPNCredentialsOTPMethod, allocator, "\"none\""));
    try std.testing.expectEqual(api.OpenVPNCredentialsOTPMethod.append, try parseFromJson(api.OpenVPNCredentialsOTPMethod, allocator, "\"append\""));
    try std.testing.expectEqual(api.OpenVPNCredentialsOTPMethod.encode, try parseFromJson(api.OpenVPNCredentialsOTPMethod, allocator, "\"encode\""));
    try std.testing.expectError(error.UnsupportedModel, parseFromJson(api.OpenVPNCredentialsOTPMethod, allocator, "\"bogus\""));
    try std.testing.expectError(error.InvalidModel, parseFromJson(api.OpenVPNCredentialsOTPMethod, allocator, "{}"));
}

test "round-trips OpenVPN TLS wrap strategies" {
    try expectRoundTrip(api.OpenVPNTLSWrap,
        \\{"strategy":"auth","key":{"data":"AQID","dir":1}}
    );
    try expectRoundTrip(api.OpenVPNTLSWrap,
        \\{"strategy":"crypt","key":{"data":"AQID"}}
    );
    try expectRoundTrip(api.OpenVPNTLSWrap,
        \\{"strategy":"crypt-v2","key":{"data":"AQID","dir":1},"wrappedKey":"ECAwQA=="}
    );
}

test "parses IP settings and module types" {
    try expectRoundTrip(api.IPSettings,
        \\{"subnets":["10.10.0.2/24"],"includedRoutes":[],"excludedRoutes":[]}
    );

    const allocator = std.testing.allocator;
    try std.testing.expectEqual(api.ModuleType.WireGuard, try parseFromJson(api.ModuleType, allocator, "\"WireGuard\""));
    try std.testing.expectEqual(api.ModuleType.OpenVPN, try parseFromJson(api.ModuleType, allocator, "\"OpenVPN\""));
    try std.testing.expectError(error.UnsupportedModel, parseFromJson(api.ModuleType, allocator, "\"DoesNotExist\""));
}

test "encodes tagged module discriminators" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator, tagged_profile_json);
    defer profile.deinit(allocator);

    const encoded = try util.encodeJsonValue(allocator, profile);
    defer allocator.free(encoded);

    try expectJsonContains(encoded, "\"type\":\"DNS\"");
    try expectJsonContains(encoded, "\"type\":\"HTTPProxy\"");
    try expectJsonContains(encoded, "\"type\":\"IP\"");
    try expectJsonContains(encoded, "\"type\":\"OnDemand\"");
    try expectJsonContains(encoded, "\"type\":\"OpenVPN\"");
    try expectJsonContains(encoded, "\"type\":\"WireGuard\"");
}

test "round-trips every tagged module case" {
    inline for (tagged_module_jsons) |module_json| {
        try expectRoundTrip(api.TaggedModule, module_json);
    }

    const allocator = std.testing.allocator;
    var wireguard = try api.TaggedModule.parse(allocator, tagged_wireguard_json);
    defer wireguard.deinit(allocator);
    try std.testing.expectEqual(api.ModuleType.WireGuard, switch (wireguard) {
        .WireGuard => api.ModuleType.WireGuard,
        else => api.ModuleType.Undefined,
    });
}

test "rejects unknown tagged module discriminators" {
    try std.testing.expectError(
        error.UnsupportedModel,
        parseFromJson(api.TaggedModule, std.testing.allocator,
            \\{"type":"Bogus","value":{}}
        ),
    );
}

test "round-trips tagged profiles" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator, tagged_profile_json);
    defer profile.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 7), profile.version.?);
    try std.testing.expectEqualStrings("Serialization Fixture", profile.name);
    try std.testing.expectEqual(@as(usize, 6), profile.modules.len);
    try std.testing.expectEqual(@as(usize, 5), profile.active_modules_ids.len);
    try std.testing.expect(profile.behavior.?.disconnects_on_sleep);
    try std.testing.expectEqual(true, profile.behavior.?.includes_all_networks.?);

    const encoded = try util.encodeJsonValue(allocator, profile);
    defer allocator.free(encoded);
    var decoded = try api.Profile.parse(allocator, encoded);
    defer decoded.deinit(allocator);
    const reencoded = try util.encodeJsonValue(allocator, decoded);
    defer allocator.free(reencoded);
    try std.testing.expectEqualStrings(encoded, reencoded);
}

test "round-trips tunnel remote info wrappers" {
    try expectRoundTrip(api.TunnelRemoteInfoWrapper, tunnel_remote_info_json);
}

fn expectAddress(raw: []const u8, family: api.Address.Family) !void {
    const parsed = api.Address.parseRaw(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(family, parsed.family);
}

fn expectAddressNotIP(raw: []const u8) !void {
    const parsed = api.Address.parseRaw(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!parsed.isIPAddress());
}

fn expectEndpoint(raw: []const u8, address: []const u8, port: u16, family: api.Address.Family) !void {
    const endpoint = api.Endpoint.parseRaw(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(address, endpoint.address);
    try std.testing.expectEqual(port, endpoint.port);
    try std.testing.expectEqual(family, endpointFamily(endpoint));
}

fn expectEndpointFailure(raw: []const u8, family: api.Address.Family) !void {
    const endpoint = api.Endpoint.parseRaw(raw) orelse return;
    try std.testing.expect(endpointFamily(endpoint) != family);
}

fn endpointFamily(endpoint: api.Endpoint) api.Address.Family {
    return (api.Address.parseRaw(endpoint.address) orelse unreachable).family;
}

fn expectExtendedEndpoint(
    raw: []const u8,
    address: []const u8,
    socket_type: api.IPSocketType,
    port: u16,
    family: api.Address.Family,
) !void {
    const endpoint = api.ExtendedEndpoint.parseRaw(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(address, endpoint.address);
    try std.testing.expectEqual(socket_type, endpoint.proto.socket_type);
    try std.testing.expectEqual(port, endpoint.proto.port);
    try std.testing.expectEqual(family, (api.Address.parseRaw(endpoint.address) orelse unreachable).family);
}

fn expectExtendedEndpointFailure(raw: []const u8, family: api.Address.Family) !void {
    const endpoint = api.ExtendedEndpoint.parseRaw(raw) orelse return;
    try std.testing.expect((api.Address.parseRaw(endpoint.address) orelse unreachable).family != family);
}

fn expectSubnet(raw: []const u8, address: []const u8, prefix_length: u8, family: api.Address.Family) !void {
    const subnet = api.Subnet.parseRaw(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(address, subnet.address.raw);
    try std.testing.expectEqual(prefix_length, subnet.prefix_length);
    try std.testing.expectEqual(family, subnet.address.family);
}

fn expectSubnetFailure(raw: []const u8, family: api.Address.Family) !void {
    const subnet = api.Subnet.parseRaw(raw) orelse return;
    try std.testing.expect(subnet.address.family != family);
}

fn expectNetworkRaw(raw: []const u8, expected: []const u8) !void {
    const subnet = api.Subnet.parseRaw(raw) orelse return error.TestUnexpectedResult;
    const network = try subnet.networkRawAlloc(std.testing.allocator);
    defer std.testing.allocator.free(network);
    try std.testing.expectEqualStrings(expected, network);
}

fn expectRoundTrip(comptime T: type, json: []const u8) !void {
    const allocator = std.testing.allocator;

    var value = try parseFromJson(T, allocator, json);
    defer deinitParsed(T, allocator, &value);

    const encoded = try util.encodeJsonValue(allocator, value);
    defer allocator.free(encoded);

    var decoded = try parseFromJson(T, allocator, encoded);
    defer deinitParsed(T, allocator, &decoded);

    const reencoded = try util.encodeJsonValue(allocator, decoded);
    defer allocator.free(reencoded);
    try std.testing.expectEqualStrings(encoded, reencoded);
}

fn encodedFromJson(comptime T: type, json: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    var value = try parseFromJson(T, allocator, json);
    defer deinitParsed(T, allocator, &value);
    return util.encodeJsonValue(allocator, value);
}

fn parseFromJson(comptime T: type, allocator: std.mem.Allocator, json: []const u8) !T {
    if (comptime std.meta.hasFn(T, "parse")) {
        return T.parse(allocator, json);
    }
    var parsed = try util.parseJsonValue(allocator, json);
    defer parsed.deinit();
    return T.parseValue(allocator, parsed.value);
}

fn deinitParsed(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    if (comptime std.meta.hasFn(T, "deinit")) {
        value.deinit(allocator);
    }
}

fn expectJsonContains(json: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}

const key_01 = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
const key_02 = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";
const key_03 = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=";

const certificate_pem =
    \\-----BEGIN CERTIFICATE-----
    \\certificate-body
    \\-----END CERTIFICATE-----
;

const certificate_pem_json = "-----BEGIN CERTIFICATE-----\\ncertificate-body\\n-----END CERTIFICATE-----";

const tagged_dns_json =
    \\{"type":"DNS","value":{"id":"00000000-0000-0000-0000-000000000102","protocolType":{"type":"https","url":"https://dns.example.com/query"},"servers":["1.1.1.1","2606:4700:4700::1111"],"domainName":"primary.example.com","searchDomains":["primary.example.com","search.example.com"],"inheritsVPN":false,"domainPolicy":"matchAndSearch","routesThroughVPN":true}}
;

const tagged_http_proxy_json =
    \\{"type":"HTTPProxy","value":{"id":"00000000-0000-0000-0000-000000000103","proxy":"10.0.0.20:3128","secureProxy":"10.0.0.21:3129","pacURL":"https://proxy.example.com/proxy.pac","bypassDomains":["internal.example.com","localhost"]}}
;

const tagged_ip_json =
    \\{"type":"IP","value":{"id":"00000000-0000-0000-0000-000000000104","ipv4":{"subnets":["10.8.0.2/24"],"includedRoutes":[{"destination":"172.16.0.0/12","gateway":"10.8.0.1"}],"excludedRoutes":[{"destination":"192.168.0.0/16"}]},"ipv6":{"subnets":["2001:db8:1::2/64"],"includedRoutes":[{"destination":"2001:db8:100::/48","gateway":"2001:db8::1"}],"excludedRoutes":[{"destination":"fd00:dead:beef::/48"}]},"mtu":1380}}
;

const tagged_on_demand_json =
    \\{"type":"OnDemand","value":{"id":"00000000-0000-0000-0000-000000000105","policy":"including","withSSIDs":{"Office WiFi":true,"Guest WiFi":false},"withOtherNetworks":["mobile","ethernet"]}}
;

const tagged_openvpn_json =
    \\{"type":"OpenVPN","value":{"id":"00000000-0000-0000-0000-000000000106","configuration":{"cipher":"AES-256-CBC","authUserPass":true,"staticChallenge":true,"remotes":["vpn.example.com:UDP4:1194"],"xorMethod":{"type":"obfuscate","mask":"BAUG"}},"credentials":{"username":"ovpn-user","password":"ovpn-password","otpMethod":"encode","otp":"654321"},"requiresInteractiveCredentials":true}}
;

const tagged_wireguard_json =
    \\{"type":"WireGuard","value":{"id":"00000000-0000-0000-0000-000000000107","configuration":{"interface":{"privateKey":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","addresses":["10.14.0.2/32"],"mtu":1280},"peers":[{"publicKey":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=","preSharedKey":"AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=","endpoint":"wg.example.com:51820","allowedIPs":["0.0.0.0/0","::/0"],"keepAlive":25}]}}}
;

const tagged_module_jsons = .{
    tagged_dns_json,
    tagged_http_proxy_json,
    tagged_ip_json,
    tagged_on_demand_json,
    tagged_openvpn_json,
    tagged_wireguard_json,
};

const tagged_profile_json =
    \\{"version":7,"id":"00000000-0000-0000-0000-000000000100","name":"Serialization Fixture","modules":[
++ tagged_dns_json ++ "," ++ tagged_http_proxy_json ++ "," ++ tagged_ip_json ++ "," ++ tagged_on_demand_json ++ "," ++ tagged_openvpn_json ++ "," ++ tagged_wireguard_json ++
    \\],"activeModulesIds":["00000000-0000-0000-0000-000000000102","00000000-0000-0000-0000-000000000103","00000000-0000-0000-0000-000000000104","00000000-0000-0000-0000-000000000105","00000000-0000-0000-0000-000000000106"],"behavior":{"disconnectsOnSleep":true,"includesAllNetworks":true},"userInfo":{"owner":"PartoutCoreTests","priority":42}}
;

const tunnel_remote_info_json =
    \\{"profile":
++ tagged_profile_json ++
    \\,"originalModuleId":"00000000-0000-0000-0000-000000000106","address":"198.51.100.44","requiresVirtualDevice":true,"modules":[
++ tagged_dns_json ++ "," ++ tagged_ip_json ++
    \\]}
;
