// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const build_options = @import("build_options");

const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const helpers = @import("helpers.zig");
const net = @import("../net/exports.zig");
const openvpn = @import("../openvpn/exports.zig");
const wireguard = @import("../wireguard/exports.zig");

const api = core.api;
const c = helpers.c;
const c_common = c_mod.common;
const util = core.util;

pub const RuntimeError = net.DaemonError || error{
    CacheDirectory,
    InvalidArgs,
    InvalidProfile,
};

pub const DaemonOptions = struct {
    profile: api.Profile,
    cache_dir: [:0]const u8,
    is_daemon: bool,
    starts_immediately: bool,
    cancels_unrecoverable: bool,
    min_data_count_delta: u64,
    crypto_backend: ?c_mod.CryptoBackend,

    pub fn init(
        allocator: std.mem.Allocator,
        args: c.partout_daemon_start_args,
        error_info: ?*api.JsonErrorInfo,
    ) RuntimeError!DaemonOptions {
        const c_profile = args.profile orelse return error.InvalidArgs;

        // Parse the profile from a JSON. This step doesn't recognize
        // a serialized module representation, for which a former
        // import call is required to obtain a profile from a serialized
        // module
        const profile_json = util.borrowedCString(c_profile);
        var profile = api.Profile.parseWithErrorInfo(allocator, profile_json, error_info) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidProfile,
            };
        };
        errdefer profile.deinit(allocator);

        // Leave early if the active connection module has no runtime
        // implementation. A protocol may be built for parsing and
        // serialization while its connection implementation is unavailable.
        try validateSupportedImplementations(&profile);

        // Scope the cache root to this profile.
        const cache_root = if (args.options.cache_dir) |value|
            try allocator.dupe(u8, util.borrowedCString(value))
        else
            try util.defaultCacheDir(allocator);
        defer allocator.free(cache_root);
        const cache_directory_name = try std.fmt.allocPrint(
            allocator,
            "partout-{s}",
            .{profile.id[0..]},
        );
        defer allocator.free(cache_directory_name);
        const cache_dir = try std.fs.path.joinZ(
            allocator,
            &.{ cache_root, cache_directory_name },
        );
        errdefer allocator.free(cache_dir);

        // Fall back to default crypto backend.
        const crypto_backend = std.enums.fromInt(c_mod.CryptoBackend, args.options.crypto);

        return .{
            .profile = profile,
            .cache_dir = cache_dir,
            .is_daemon = args.options.is_daemon,
            .starts_immediately = args.options.starts_immediately,
            .cancels_unrecoverable = args.options.cancels_unrecoverable,
            .min_data_count_delta = args.options.min_data_count_delta,
            .crypto_backend = crypto_backend,
        };
    }

    pub fn deinit(self: *const DaemonOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_dir);
        self.profile.deinit(allocator);
    }

    fn validateSupportedImplementations(profile: *const api.Profile) RuntimeError!void {
        const module = api.findActiveConnectionModule(profile) orelse return;
        switch (api.moduleType(module)) {
            .OpenVPN => if (!build_options.openvpn) return error.MissingConnectionImplementation,
            .WireGuard => if (!build_options.wireguard) return error.MissingConnectionImplementation,
            else => {},
        }
    }
};

pub const DaemonRuntime = struct {
    const Context = union(api.ModuleType) {
        Custom: void,
        DNS: void,
        HTTPProxy: void,
        IP: void,
        OnDemand: void,
        OpenVPN: openvpn.ConnectionContext,
        Provider: void,
        WireGuard: wireguard.ConnectionContext,
        Undefined: void,
    };

    registry: net.ConnectionRegistry,
    daemon: *net.Daemon,
    platform: net.Platform,
    options: DaemonOptions,
    events: helpers.BoundDaemonEvents,

    // Copy these for release() on deinit
    bindings: ?c.partout_daemon_bindings,
    contexts: std.EnumMap(api.ModuleType, Context),

    pub fn init(
        allocator: std.mem.Allocator,
        options: DaemonOptions,
        bindings: ?*const c.partout_daemon_bindings,
    ) RuntimeError!*DaemonRuntime {
        if (!c_common.pp_file_create_directory(options.cache_dir.ptr))
            return error.CacheDirectory;

        const self = try allocator.create(DaemonRuntime);
        errdefer allocator.destroy(self);

        // Register the known connection implementations
        var contexts: std.EnumMap(api.ModuleType, Context) = .{};
        var impls: std.ArrayList(net.ConnectionImplementation) = .empty;
        defer impls.deinit(allocator);
        if (build_options.openvpn and c_mod.has_default_crypto_backend) {
            const ctx: openvpn.ConnectionContext = .{ .session_options = .{
                .backend = options.crypto_backend orelse .default(),
            } };
            contexts.put(.OpenVPN, .{ .OpenVPN = ctx });
            const impl: net.ConnectionImplementation = .{
                .ptr = @constCast(&ctx),
                .vtable = &openvpn.connection_vtable,
            };
            try impls.append(allocator, impl);
        }
        if (build_options.wireguard) {
            const ctx: wireguard.ConnectionContext = .{
                .backend = wireguard.go_backend,
            };
            contexts.put(.WireGuard, .{ .WireGuard = ctx });
            const impl: net.ConnectionImplementation = .{
                .ptr = @constCast(&ctx),
                .vtable = &wireguard.connection_vtable,
            };
            try impls.append(allocator, impl);
        }
        self.registry = try net.ConnectionRegistry.init(allocator, impls.items);
        errdefer self.registry.deinit(allocator);

        // Build the daemon with the platform implementations
        self.platform = try net.Platform.init(.{
            .ref = if (bindings) |b| b.*.controller else null,
        });
        errdefer self.platform.deinit();
        self.events = helpers.BoundDaemonEvents.init(bindings);
        self.daemon = try net.Daemon.create(
            allocator,
            &options.profile,
            .{
                .objects = .{
                    .registry = &self.registry,
                    .controller = self.platform.tunnelController(),
                    .resolver = self.platform.dnsResolver(),
                    .factory = self.platform.socketFactory(),
                    .monitor = self.platform.networkMonitor(),
                },
                .options = .{
                    .starts_immediately = options.starts_immediately,
                    .cancels_unrecoverable = options.cancels_unrecoverable,
                    .min_data_count_delta = options.min_data_count_delta,
                    .events = self.events.interface(),
                    .cache_dir = options.cache_dir,
                },
            },
        );
        errdefer self.daemon.destroy();

        // Bind the platform to the underlying OS callbacks
        self.platform.attach();

        self.options = options;
        self.bindings = if (bindings) |b| b.* else null;
        self.contexts = contexts;
        return self;
    }

    pub fn destroy(self: *DaemonRuntime, allocator: std.mem.Allocator) void {
        self.daemon.destroy();
        self.platform.deinit();
        self.registry.deinit(allocator);
        self.options.deinit(allocator);

        if (self.bindings) |bindings| {
            if (bindings.release) |release| {
                release(@constCast(&bindings));
            }
        }
        allocator.destroy(self);
    }

    pub fn start(self: *const DaemonRuntime) RuntimeError!void {
        return try self.daemon.start();
    }

    pub fn hold(self: *const DaemonRuntime) void {
        self.daemon.hold();
    }

    pub fn stop(self: *const DaemonRuntime) void {
        self.daemon.stop();
    }
};
