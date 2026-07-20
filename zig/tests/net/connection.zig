// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const conn = @import("source").net_connection;
const core = @import("source").core;
const mock_mod = @import("source").mock;
const sandbox = @import("source").net_sandbox;

const api = core.api;

const ConnectionRegistry = conn.ConnectionRegistry;
const activeConnectionModule = conn.activeConnectionModule;

test "connection options match Swift defaults" {
    const options = sandbox.ConnectionOptions{};

    try std.testing.expectEqual(@as(u32, 3000), options.dns_timeout);
    try std.testing.expectEqual(@as(u32, 5000), options.link_activity_timeout);
    try std.testing.expectEqual(@as(u32, 5000), options.link_write_timeout);
    try std.testing.expectEqual(@as(u32, 1000), options.min_data_count_interval);
    try std.testing.expect(options.user_info == null);
}

test "finds the active connection module" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-0000-0000-000000000100","name":"Connection","modules":[
        \\{"type":"OpenVPN","value":{"id":"00000000-0000-0000-0000-000000000106","configuration":{"remotes":[]},"requiresInteractiveCredentials":true}},
        \\{"type":"WireGuard","value":{"id":"00000000-0000-0000-0000-000000000107","configuration":{"interface":{"privateKey":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","addresses":[]},"peers":[]}}},
        \\{"type":"DNS","value":{"id":"00000000-0000-0000-0000-000000000102","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
        \\],"activeModulesIds":["00000000-0000-0000-0000-000000000107","00000000-0000-0000-0000-000000000102"]}
    );
    defer profile.deinit(allocator);

    try std.testing.expect(api.hasConnection(profile));
    try std.testing.expect(api.isActiveProfileModule(profile, profile.active_modules_ids[0]));
    const active = activeConnectionModule(profile) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.ModuleType.WireGuard, active.typeOf());
    const active_id = active.id();
    try std.testing.expectEqualStrings("00000000-0000-0000-0000-000000000107", active_id[0..]);
    try std.testing.expect(!active.isInteractive());
}

test "ignores inactive connection modules" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-0000-0000-000000000100","name":"Inactive","modules":[
        \\{"type":"OpenVPN","value":{"id":"00000000-0000-0000-0000-000000000106","configuration":{"remotes":[]},"requiresInteractiveCredentials":true}},
        \\{"type":"DNS","value":{"id":"00000000-0000-0000-0000-000000000102","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
        \\],"activeModulesIds":["00000000-0000-0000-0000-000000000102"]}
    );
    defer profile.deinit(allocator);

    try std.testing.expect(!api.hasConnection(profile));
    try std.testing.expect(api.findActiveConnectionModule(profile) == null);
}

test "reports interactive OpenVPN connections" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-0000-0000-000000000100","name":"Interactive","modules":[
        \\{"type":"OpenVPN","value":{"id":"00000000-0000-0000-0000-000000000106","configuration":{"remotes":[]},"requiresInteractiveCredentials":true}}
        \\],"activeModulesIds":["00000000-0000-0000-0000-000000000106"]}
    );
    defer profile.deinit(allocator);

    const active = activeConnectionModule(profile) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.ModuleType.OpenVPN, active.typeOf());
    try std.testing.expect(active.isInteractive());
}

test "empty connection registry reports absent implementation" {
    const mock = mock_mod;
    const allocator = std.testing.allocator;
    var registry = try ConnectionRegistry.init(allocator, &.{});
    defer registry.deinit(allocator);
    var profile = try api.Profile.parse(allocator, mock.connectionProfileJson());
    defer profile.deinit(allocator);

    const module = activeConnectionModule(profile) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(
        error.MissingConnectionImplementation,
        registry.createConnection(allocator, module, .{
            .profile = &profile,
            .controller = mock.noopTunnelController(),
            .resolver = mock.noopDNSResolver(),
            .factory = mock.noopSocketFactory(),
            .monitor = mock.alwaysReachableMonitor(),
        }),
    );
}
