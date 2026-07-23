// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const conn = @import("source").net_connection;
const net_daemon = @import("source").net_daemon;
const helpers = @import("source").abi_helpers;
const abi_runtime = @import("source").abi_runtime;
const mock = @import("source").mock;

const api = core.api;
const c = helpers.c;
const MockDaemonRuntime = mock.MockDaemonRuntime;

fn createDaemonWithJson(
    allocator: std.mem.Allocator,
    profile_json: []const u8,
    context: net_daemon.Context,
) (api.DecodeError || net_daemon.Error)!*net_daemon.Daemon {
    var profile = try api.Profile.parse(allocator, profile_json);
    defer profile.deinit(allocator);
    return net_daemon.Daemon.create(allocator, &profile, context);
}

fn daemonStartArgs(profile: ?[*:0]const u8) c.partout_daemon_start_args {
    return .{
        .profile = profile,
        .options = .{
            .is_daemon = false,
            .starts_immediately = false,
            .cache_dir = "/tmp",
            .min_data_count_delta = 4096,
        },
        .bindings = null,
    };
}

test "daemon options parse DNS-only profile" {
    const allocator = std.testing.allocator;
    var options = try abi_runtime.DaemonOptions.init(
        allocator,
        daemonStartArgs(mock.dnsOnlyProfileJson().ptr),
        null,
    );
    defer options.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp", options.cache_dir);
    try std.testing.expect(!options.is_daemon);
    try std.testing.expectEqual(@as(u64, 4096), options.min_data_count_delta);
}

test "daemon options reject invalid args" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidArgs,
        abi_runtime.DaemonOptions.init(allocator, daemonStartArgs(null), null),
    );
}

test "daemon options default cache directory" {
    const allocator = std.testing.allocator;
    var args = daemonStartArgs(mock.dnsOnlyProfileJson().ptr);
    args.options.cache_dir = null;
    var options = try abi_runtime.DaemonOptions.init(
        allocator,
        args,
        null,
    );
    defer options.deinit(allocator);

    try std.testing.expect(options.cache_dir.len > 0);
}

test "daemon options reject missing connection implementation" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MissingConnectionImplementation,
        abi_runtime.DaemonOptions.init(
            allocator,
            daemonStartArgs(mock.connectionProfileJson().ptr),
            null,
        ),
    );
}

test "daemon runtime owns options during lifecycle" {
    const allocator = std.testing.allocator;
    const options = try abi_runtime.DaemonOptions.init(
        allocator,
        daemonStartArgs(mock.dnsOnlyProfileJson().ptr),
        null,
    );
    const runtime = try abi_runtime.DaemonRuntime.init(allocator, options, null);

    try runtime.start(allocator);
    runtime.stop();
    runtime.deinit(allocator);
}

test "starts DNS-only profile through tunnel controller" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{};
    var registry = try emptyConnectionRegistry(allocator);
    defer registry.deinit(allocator);
    var daemon = try createDaemonWithJson(
        allocator,
        mock.dnsOnlyProfileJson(),
        runtime.context(&registry),
    );
    defer daemon.deinit(allocator);

    try daemon.start(allocator);

    try std.testing.expect(daemon.isSettingsOnly());
    try std.testing.expectEqual(@as(usize, 1), runtime.controller.set_tunnel_settings_count);
    const settings = runtime.controller.last_settings orelse return error.TestUnexpectedResult;
    try std.testing.expect(!settings.requires_virtual_device);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", settings.original_module_id[0..]);
    try std.testing.expectEqual(@as(usize, 1), settings.module_count);
    try std.testing.expect(settings.has_dns_module);
    try std.testing.expectEqual(@as(usize, 2), settings.dns_server_count);
    try std.testing.expectEqualStrings("1.1.1.1", settings.dnsServer(0));
    try std.testing.expectEqualStrings("9.9.9.9", settings.dnsServer(1));

    daemon.stop();
    try std.testing.expect(daemon.isSettingsOnly());
    try std.testing.expectEqual(@as(usize, 1), runtime.controller.clear_tunnel_settings_count);
}

test "starts profile without active modules without tunnel settings" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{};
    var registry = try emptyConnectionRegistry(allocator);
    defer registry.deinit(allocator);
    const empty_profile_json =
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"empty","modules":[],"activeModulesIds":[]}
    ;
    var daemon = try createDaemonWithJson(
        allocator,
        empty_profile_json,
        runtime.context(&registry),
    );
    defer daemon.deinit(allocator);

    try daemon.start(allocator);
    defer daemon.stop();

    try std.testing.expect(daemon.isSettingsOnly());
    try std.testing.expect(!daemon.isConnectionProfile());
    try std.testing.expectEqual(@as(usize, 0), runtime.controller.set_tunnel_settings_count);
}

test "requires a connection implementation for active connection profiles" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{};
    var registry = try emptyConnectionRegistry(allocator);
    defer registry.deinit(allocator);
    try std.testing.expectError(
        error.MissingConnectionImplementation,
        createDaemonWithJson(
            allocator,
            mock.connectionProfileJson(),
            runtime.context(&registry),
        ),
    );
}

test "starts and stops connection profile through injected dependencies" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{};
    var registry = try mockConnectionRegistry(allocator);
    defer registry.deinit(allocator);
    var daemon = try createDaemonWithJson(allocator, mock.connectionProfileJson(), runtime.context(&registry));
    defer daemon.deinit(allocator);

    try std.testing.expect(daemon.isConnectionProfile());

    try daemon.start(allocator);

    try std.testing.expectEqual(@as(usize, 1), runtime.monitor.start_count);
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
        .connecting,
        .connected,
    }, daemon.testStatuses());
    try std.testing.expectEqual(.connected, runtime.events.connection_status.?);
    try std.testing.expectEqual(.authentication, runtime.events.last_error_code.?);
    try std.testing.expectEqual(@as(u64, 10), runtime.events.data_count.received);
    try std.testing.expectEqual(@as(u64, 20), runtime.events.data_count.sent);
    try std.testing.expect(!runtime.controller.reasserting);

    daemon.stop();
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
        .connecting,
        .connected,
        .disconnecting,
        .disconnected,
    }, daemon.testStatuses());
    try std.testing.expectEqual(@as(usize, 1), runtime.monitor.stop_count);
    try std.testing.expect(runtime.events.connection_status == null);
    try std.testing.expect(runtime.events.last_error_code == null);
    try std.testing.expect(!runtime.events.has_data_count);
}

test "stop blocks until connection teardown finishes" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{};
    var blocking_connection = mock.BlockingStopConnection{};
    var registry = try blockingConnectionRegistry(allocator, &blocking_connection);
    defer registry.deinit(allocator);
    var daemon = try createDaemonWithJson(
        allocator,
        mock.connectionProfileJson(),
        runtime.context(&registry),
    );
    defer daemon.deinit(allocator);

    try daemon.start(allocator);

    daemon.stop();

    try std.testing.expectEqual(@as(usize, 1), blocking_connection.stop_count);
    try std.testing.expect(runtime.events.connection_status == null);
    try std.testing.expect(runtime.events.last_error_code == null);
}

test "network monitor gates immediate connection evaluation" {
    const allocator = std.testing.allocator;
    var runtime: MockDaemonRuntime = .{ .monitor = .{ .reachable = false } };
    var registry = try mockConnectionRegistry(allocator);
    defer registry.deinit(allocator);
    var daemon = try createDaemonWithJson(allocator, mock.connectionProfileJson(), runtime.context(&registry));
    defer daemon.deinit(allocator);

    try daemon.start(allocator);
    defer daemon.stop();

    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{.disconnected}, daemon.testStatuses());
    try std.testing.expectEqual(.disconnected, runtime.events.connection_status.?);
    try std.testing.expect(!runtime.controller.reasserting);
}
fn emptyConnectionRegistry(allocator: std.mem.Allocator) error{OutOfMemory}!conn.ConnectionRegistry {
    return conn.ConnectionRegistry.init(allocator, &.{});
}

fn mockConnectionRegistry(allocator: std.mem.Allocator) error{OutOfMemory}!conn.ConnectionRegistry {
    const implementations = [_]conn.ConnectionImplementation{
        mock.mockConnectionImplementation(),
    };
    return conn.ConnectionRegistry.init(allocator, &implementations);
}

fn blockingConnectionRegistry(
    allocator: std.mem.Allocator,
    blocking_connection: *mock.BlockingStopConnection,
) error{OutOfMemory}!conn.ConnectionRegistry {
    const implementations = [_]conn.ConnectionImplementation{
        mock.blockingConnectionImplementation(blocking_connection),
    };
    return conn.ConnectionRegistry.init(allocator, &implementations);
}
