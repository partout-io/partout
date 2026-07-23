// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const NetworkSettingsBuilder = source.openvpn_internal.settings.NetworkSettingsBuilder;

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
