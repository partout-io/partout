// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const NetworkSettingsBuilder = source.openvpn_internal.settings.NetworkSettingsBuilder;

test "NetworkSettingsBuilder requires a remote tunnel address for IP settings" {
    const allocator = std.testing.allocator;
    const local = api.OpenVPNConfiguration{};

    {
        const remote = api.OpenVPNConfiguration{};
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }

    {
        const subnets = [_]api.Subnet{api.Subnet.parseRaw("100.1.2.3/32").?};
        const remote = api.OpenVPNConfiguration{
            .ipv4 = .{ .subnets = &subnets },
        };
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expect(result[0] == .IP);
    }
}

test "NetworkSettingsBuilder merges local and pushed routes unless routes are masked" {
    const allocator = std.testing.allocator;
    const subnets = [_]api.Subnet{api.Subnet.parseRaw("100.1.2.3/32").?};
    const local_routes = [_]api.Route{
        .{ .destination = api.Subnet.parseRaw("1.1.0.0/16").? },
        .{ .destination = api.Subnet.parseRaw("2.0.0.0/8").? },
    };
    const remote_routes = [_]api.Route{
        .{ .destination = api.Subnet.parseRaw("3.3.3.0/24").? },
        .{ .destination = api.Subnet.parseRaw("4.4.4.4/32").? },
    };
    const remote = api.OpenVPNConfiguration{
        .ipv4 = .{ .subnets = &subnets },
        .routes4 = &remote_routes,
    };

    {
        const local = api.OpenVPNConfiguration{ .routes4 = &local_routes };
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        const routes = result[0].IP.ipv4.?.included_routes;
        try std.testing.expectEqual(@as(usize, 4), routes.len);
        try std.testing.expectEqualStrings("1.1.0.0", routes[0].destination.?.address.raw);
        try std.testing.expectEqualStrings("4.4.4.4", routes[3].destination.?.address.raw);
    }

    {
        const masks = [_]api.OpenVPNPullMask{.routes};
        const local = api.OpenVPNConfiguration{
            .routes4 = &local_routes,
            .no_pull_mask = &masks,
        };
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        const routes = result[0].IP.ipv4.?.included_routes;
        try std.testing.expectEqual(@as(usize, 2), routes.len);
        try std.testing.expectEqualStrings("1.1.0.0", routes[0].destination.?.address.raw);
        try std.testing.expectEqualStrings("2.0.0.0", routes[1].destination.?.address.raw);
    }
}

test "NetworkSettingsBuilder applies routing policies and remote gateways" {
    const allocator = std.testing.allocator;
    const subnets4 = [_]api.Subnet{api.Subnet.parseRaw("1.1.1.1/16").?};
    const subnets6 = [_]api.Subnet{api.Subnet.parseRaw("2001:db8::1/72").?};
    const policies = [_]api.OpenVPNRoutingPolicy{.IPv4};
    const local_route4 = [_]api.Route{
        .{ .destination = api.Subnet.parseRaw("50.50.50.0/24").? },
    };
    const local_route6 = [_]api.Route{
        .{ .destination = api.Subnet.parseRaw("2001:db8:50::/64").? },
    };
    const local = api.OpenVPNConfiguration{
        .routes4 = &local_route4,
        .routes6 = &local_route6,
    };
    const remote = api.OpenVPNConfiguration{
        .ipv4 = .{ .subnets = &subnets4 },
        .ipv6 = .{ .subnets = &subnets6 },
        .route_gateway4 = api.Address.parseRaw("6.6.6.6"),
        .route_gateway6 = api.Address.parseRaw("2001:db8::6"),
        .routing_policies = &policies,
    };
    const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, result);
    const ip = result[0].IP;

    try std.testing.expectEqual(@as(usize, 2), ip.ipv4.?.included_routes.len);
    try std.testing.expectEqualStrings(
        "6.6.6.6",
        ip.ipv4.?.included_routes[0].gateway.?.raw,
    );
    try std.testing.expect(ip.ipv4.?.included_routes[1].destination == null);
    try std.testing.expectEqualStrings(
        "6.6.6.6",
        ip.ipv4.?.included_routes[1].gateway.?.raw,
    );
    try std.testing.expectEqual(@as(usize, 1), ip.ipv6.?.included_routes.len);
    try std.testing.expectEqualStrings(
        "2001:db8::6",
        ip.ipv6.?.included_routes[0].gateway.?.raw,
    );
}

test "NetworkSettingsBuilder gives remote DNS precedence" {
    const allocator = std.testing.allocator;
    const local_servers = [_][]const u8{"1.1.1.1"};
    const remote_servers = [_][]const u8{"9.9.9.9"};
    const local = api.OpenVPNConfiguration{ .dns_servers = &local_servers };
    const remote = api.OpenVPNConfiguration{ .dns_servers = &remote_servers };
    const builder = NetworkSettingsBuilder.init(&local, &remote);
    const result = try builder.modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 2), result[0].DNS.servers.len);
}

test "NetworkSettingsBuilder merges DNS servers and domains unless DNS is masked" {
    const allocator = std.testing.allocator;
    const local_servers = [_][]const u8{ "1.1.1.1", "2.2.2.2" };
    const remote_servers = [_][]const u8{"3.3.3.3"};
    const local_search = [_][]const u8{ "one.example", "two.example" };
    const remote_search = [_][]const u8{"three.example"};
    const remote = api.OpenVPNConfiguration{
        .dns_servers = &remote_servers,
        .search_domains = &remote_search,
    };

    {
        const local = api.OpenVPNConfiguration{
            .dns_servers = &local_servers,
            .search_domains = &local_search,
        };
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        const dns = result[0].DNS;
        try std.testing.expectEqual(@as(usize, 3), dns.servers.len);
        try std.testing.expectEqualStrings("1.1.1.1", dns.servers[0].raw);
        try std.testing.expectEqualStrings("3.3.3.3", dns.servers[2].raw);
        try std.testing.expectEqual(@as(usize, 3), dns.search_domains.?.len);
        try std.testing.expectEqualStrings(
            "three.example",
            dns.search_domains.?[2].raw,
        );
    }

    {
        const masks = [_]api.OpenVPNPullMask{.dns};
        const local = api.OpenVPNConfiguration{
            .dns_servers = &local_servers,
            .search_domains = &local_search,
            .no_pull_mask = &masks,
        };
        const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);
        const dns = result[0].DNS;
        try std.testing.expectEqual(@as(usize, 2), dns.servers.len);
        try std.testing.expectEqual(@as(usize, 2), dns.search_domains.?.len);
    }
}

test "NetworkSettingsBuilder omits malformed DNS without discarding proxy" {
    const allocator = std.testing.allocator;
    const invalid_servers = [_][]const u8{"   "};
    const local = api.OpenVPNConfiguration{
        .dns_servers = &invalid_servers,
        .http_proxy = .{ .address = "proxy.example", .port = 8080 },
    };
    const remote = api.OpenVPNConfiguration{};
    const builder = NetworkSettingsBuilder.init(&local, &remote);
    const result = try builder.modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .HTTPProxy);
}

test "NetworkSettingsBuilder omits malformed proxy without discarding DNS" {
    const allocator = std.testing.allocator;
    const servers = [_][]const u8{"1.1.1.1"};
    const invalid_bypass = [_][]const u8{"   "};
    const local = api.OpenVPNConfiguration{
        .dns_servers = &servers,
        .http_proxy = .{ .address = "proxy.example", .port = 8080 },
        .proxy_bypass_domains = &invalid_bypass,
    };
    const remote = api.OpenVPNConfiguration{};
    const builder = NetworkSettingsBuilder.init(&local, &remote);
    const result = try builder.modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == .DNS);
}

test "NetworkSettingsBuilder applies pushed MTU with local fallback" {
    const allocator = std.testing.allocator;

    {
        const local = api.OpenVPNConfiguration{ .mtu = 1400 };
        const remote = api.OpenVPNConfiguration{ .mtu = 1300 };
        const builder = NetworkSettingsBuilder.init(&local, &remote);
        const result = try builder.modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);

        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqual(@as(?i32, 1300), result[0].IP.mtu);
    }

    {
        const local = api.OpenVPNConfiguration{ .mtu = 1400 };
        const remote = api.OpenVPNConfiguration{};
        const builder = NetworkSettingsBuilder.init(&local, &remote);
        const result = try builder.modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);

        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqual(@as(?i32, 1400), result[0].IP.mtu);
    }

    {
        const local = api.OpenVPNConfiguration{ .mtu = 1400 };
        const remote = api.OpenVPNConfiguration{ .mtu = 0 };
        const builder = NetworkSettingsBuilder.init(&local, &remote);
        const result = try builder.modules(allocator);
        defer NetworkSettingsBuilder.deinitModules(allocator, result);

        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqual(@as(?i32, 1400), result[0].IP.mtu);
    }
}

test "NetworkSettingsBuilder builds endpoint, PAC, and merged proxy bypass settings" {
    const allocator = std.testing.allocator;
    const local_bypass = [_][]const u8{ "one.example", "two.example" };
    const remote_bypass = [_][]const u8{"three.example"};
    const local = api.OpenVPNConfiguration{
        .http_proxy = .{ .address = "192.0.2.1", .port = 8080 },
        .proxy_bypass_domains = &local_bypass,
    };
    const remote = api.OpenVPNConfiguration{
        .https_proxy = .{ .address = "192.0.2.2", .port = 8443 },
        .proxy_auto_configuration_url = "https://pac.example/proxy.pac",
        .proxy_bypass_domains = &remote_bypass,
    };
    const result = try NetworkSettingsBuilder.init(&local, &remote).modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    const proxy = result[0].HTTPProxy;
    try std.testing.expectEqualStrings("192.0.2.1", proxy.proxy.?.address);
    try std.testing.expectEqualStrings("192.0.2.2", proxy.secure_proxy.?.address);
    try std.testing.expectEqualStrings(
        "https://pac.example/proxy.pac",
        proxy.pac_url.?,
    );
    try std.testing.expectEqual(@as(usize, 3), proxy.bypass_domains.len);
    try std.testing.expectEqualStrings(
        "three.example",
        proxy.bypass_domains[2].raw,
    );

    const masks = [_]api.OpenVPNPullMask{.proxy};
    const masked_local = api.OpenVPNConfiguration{
        .http_proxy = .{ .address = "192.0.2.1", .port = 8080 },
        .proxy_bypass_domains = &local_bypass,
        .no_pull_mask = &masks,
    };
    const masked_result = try NetworkSettingsBuilder.init(
        &masked_local,
        &remote,
    ).modules(allocator);
    defer NetworkSettingsBuilder.deinitModules(allocator, masked_result);
    const masked = masked_result[0].HTTPProxy;
    try std.testing.expect(masked.secure_proxy == null);
    try std.testing.expect(masked.pac_url == null);
    try std.testing.expectEqual(@as(usize, 2), masked.bypass_domains.len);
}
