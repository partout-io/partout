// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const portable_c = source.ffi.portable;
const conn = source.net_connection;
const net_daemon = source.net_daemon;
const helpers = source.abi_helpers;
const abi_runtime = source.abi_runtime;
const mock = source.mock;

const api = core.api;
const partout_c = helpers.partout_c;
const MockDaemonRuntime = mock.MockDaemonRuntime;

const profile_cache_directory = "partout-00000000-0000-4000-8000-000000000000";

fn createDaemonWithJson(
    allocator: std.mem.Allocator,
    profile_json: []const u8,
    context: net_daemon.Context,
) (api.DecodeError || net_daemon.Error)!*net_daemon.Daemon {
    var profile = try api.Profile.parse(allocator, profile_json);
    defer profile.deinit(allocator);
    return net_daemon.Daemon.create(allocator, &profile, context);
}

fn daemonStartArgs(profile: ?[*:0]const u8) partout_c.partout_daemon_start_args {
    return .{
        .profile = profile,
        .options = .{
            .is_daemon = false,
            .starts_immediately = false,
            .cancels_unrecoverable = true,
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

    try std.testing.expectEqualStrings(
        "/tmp" ++ std.fs.path.sep_str ++ profile_cache_directory,
        options.cache_dir,
    );
    try std.testing.expect(options.feature_flags.count() == 0);
    try std.testing.expect(!options.is_daemon);
    try std.testing.expect(options.cancels_unrecoverable);
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

    try std.testing.expectEqualStrings(
        profile_cache_directory,
        std.fs.path.basename(options.cache_dir),
    );
}

test "daemon options reject missing connection implementation" {
    const allocator = std.testing.allocator;
    if (source.openvpn_enabled) {
        var options = try abi_runtime.DaemonOptions.init(
            allocator,
            daemonStartArgs(mock.connectionProfileJson().ptr),
            null,
        );
        defer options.deinit(allocator);
        return;
    }
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_root = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer allocator.free(cache_root);
    const cache_root_z = try allocator.dupeZ(u8, cache_root);
    defer allocator.free(cache_root_z);
    for ([_]bool{ false, true }) |experimental| {
        var args = daemonStartArgs(mock.dnsOnlyProfileJson().ptr);
        args.options.cache_dir = cache_root_z.ptr;
        if (experimental) args.options.feature_flags = partout_c.PartoutDaemonFlagExperimentalDaemon;
        const options = try abi_runtime.DaemonOptions.init(allocator, args, null);
        const runtime = abi_runtime.DaemonRuntime.init(allocator, options, null) catch |err| {
            options.deinit(allocator);
            return err;
        };
        defer runtime.destroy(allocator);
        try std.testing.expectEqualStrings(profile_cache_directory, std.fs.path.basename(runtime.options.cache_dir));
        try std.testing.expect(portable_c.pp_file_is_directory(runtime.options.cache_dir.ptr));
        if (source.openvpn_enabled and source.ffi.has_default_crypto_backend) {
            const impl = runtime.registry.implementation(.OpenVPN).?;
            const ctx = runtime.contexts.getPtr(.OpenVPN).?;
            try std.testing.expect(impl.vtable == &source.openvpn_exports.connection_vtable);
            try std.testing.expect(impl.ptr == @as(*anyopaque, &ctx.OpenVPN));
        }
        try runtime.start();
        runtime.hold();
        runtime.stop();
    }
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
    defer daemon.destroy();

    try daemon.start();

    try std.testing.expect(daemon.isSettingsOnly());
    try std.testing.expectEqual(@as(usize, 1), runtime.controller.set_tunnel_settings_count);
    const settings = runtime.controller.last_settings orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", settings.original_module_id[0..]);
    try std.testing.expectEqual(@as(usize, 1), settings.profile_module_count);
    try std.testing.expectEqual(@as(usize, 1), settings.profile_active_module_count);
    try std.testing.expectEqual(@as(usize, 0), settings.module_count);
    try std.testing.expect(!settings.has_dns_module);

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
    defer daemon.destroy();

    try daemon.start();
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
    const daemon = try createDaemonWithJson(allocator, mock.connectionProfileJson(), runtime.context(&registry));
    defer daemon.destroy();
    try std.testing.expectError(error.MissingConnectionImplementation, daemon.start());
}

fn emptyConnectionRegistry(allocator: std.mem.Allocator) error{OutOfMemory}!conn.ConnectionRegistry {
    return conn.ConnectionRegistry.init(allocator, &.{});
}

test "daemon options decode experimental feature flags" {
    const allocator = std.testing.allocator;
    var args = daemonStartArgs(mock.dnsOnlyProfileJson().ptr);
    args.options.feature_flags = partout_c.PartoutDaemonFlagExperimentalDaemon |
        partout_c.PartoutDaemonFlagExperimentalOpenVPN |
        partout_c.PartoutDaemonFlagExperimentalWireGuard;
    var options = try abi_runtime.DaemonOptions.init(allocator, args, null);
    defer options.deinit(allocator);

    try std.testing.expect(options.feature_flags.contains(.experimentalDaemon));
    try std.testing.expect(options.feature_flags.contains(.experimentalOpenVPN));
    try std.testing.expect(options.feature_flags.contains(.experimentalWireGuard));
}

test "daemon options reject unknown feature bits" {
    var args = daemonStartArgs(mock.dnsOnlyProfileJson().ptr);
    args.options.feature_flags = @as(u64, 1) << 63;
    try std.testing.expectError(error.InvalidArgs, abi_runtime.DaemonOptions.init(std.testing.allocator, args, null));
    args.options.feature_flags |= partout_c.PartoutDaemonFlagExperimentalDaemon;
    try std.testing.expectError(error.InvalidArgs, abi_runtime.DaemonOptions.init(std.testing.allocator, args, null));
}

test "legacy feature flags preserve the current implementations" {
    const Case = struct { json: [:0]const u8, enabled: bool };
    const cases = [_]Case{
        .{ .json = mock.dnsOnlyProfileJson(), .enabled = true },
        .{ .json = mock.connectionProfileJson(), .enabled = source.openvpn_enabled },
        .{ .json =
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333"}}],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
        , .enabled = source.wireguard_enabled },
        .{ .json =
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"Inactive OpenVPN","modules":[{"type":"OpenVPN","value":{"id":"44444444-4444-4444-8444-444444444444","configuration":{}}}],"activeModulesIds":[]}
        , .enabled = source.openvpn_enabled },
    };
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_dir = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer allocator.free(cache_dir);
    for (cases) |case| {
        if (!case.enabled) continue;
        for (0..8) |flags| {
            var args = daemonStartArgs(case.json.ptr);
            args.options.cache_dir = cache_dir.ptr;
            args.options.feature_flags = flags;
            const options = try abi_runtime.DaemonOptions.init(allocator, args, null);
            const runtime = abi_runtime.DaemonRuntime.init(allocator, options, null) catch |err| {
                options.deinit(allocator);
                return err;
            };
            defer runtime.destroy(allocator);
            if (source.wireguard_enabled) {
                const impl = runtime.registry.implementation(.WireGuard).?;
                try std.testing.expect(impl.vtable == &source.wireguard_exports.connection_vtable);
                const ctx = runtime.contexts.getPtr(.WireGuard).?;
                try std.testing.expect(impl.ptr == @as(*anyopaque, &ctx.WireGuard));
                try std.testing.expect(ctx.WireGuard.backend.vtable == source.wireguard_exports.go_backend.vtable);
            }
            if (source.openvpn_enabled and source.ffi.has_default_crypto_backend) {
                const impl = runtime.registry.implementation(.OpenVPN).?;
                try std.testing.expect(impl.vtable == &source.openvpn_exports.connection_vtable);
            }
        }
    }
}
