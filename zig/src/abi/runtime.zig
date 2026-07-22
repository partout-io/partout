// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const build_options = @import("build_options");

const core = @import("../core/exports.zig");
const helpers = @import("helpers.zig");
const net = @import("../net/exports.zig");
const openvpn = @import("../openvpn/exports.zig");
const wireguard = @import("../wireguard/exports.zig");

const api = core.api;
const c = helpers.c;
const util = core.util;

pub const RuntimeError = net.DaemonError || error{
    InvalidArgs,
    InvalidProfile,
};

pub const DaemonOptions = struct {
    profile: api.Profile,
    cache_dir: []const u8,
    is_daemon: bool,
    starts_immediately: bool,
    min_data_count_delta: u64,

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
        try validateSupportedImplementations(profile);

        // Make deep copies of the other input
        const cache_dir = if (args.options.cache_dir) |value|
            try allocator.dupe(u8, util.borrowedCString(value))
        else
            try util.defaultCacheDir(allocator);
        errdefer allocator.free(cache_dir);

        return .{
            .profile = profile,
            .cache_dir = cache_dir,
            .is_daemon = args.options.is_daemon,
            .starts_immediately = args.options.starts_immediately,
            .min_data_count_delta = args.options.min_data_count_delta,
        };
    }

    pub fn deinit(self: *DaemonOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_dir);
        self.profile.deinit(allocator);
    }

    fn validateSupportedImplementations(profile: api.Profile) RuntimeError!void {
        const module = api.findActiveConnectionModule(profile) orelse return;
        switch (api.moduleType(module)) {
            .OpenVPN => if (openvpn.impl.connection == null) return error.MissingConnectionImplementation,
            .WireGuard => if (wireguard.impl.connection == null) return error.MissingConnectionImplementation,
            else => {},
        }
    }
};

pub const DaemonRuntime = struct {
    registry: net.ConnectionRegistry,
    daemon: *net.Daemon,
    platform: net.Platform,
    options: DaemonOptions,
    events: helpers.BoundDaemonEvents,

    // Copy these for release() on deinit
    bindings: ?c.partout_daemon_bindings,

    pub fn init(
        allocator: std.mem.Allocator,
        options: DaemonOptions,
        bindings: ?*const c.partout_daemon_bindings,
    ) RuntimeError!*DaemonRuntime {
        const self = try allocator.create(DaemonRuntime);
        errdefer allocator.destroy(self);

        // Register the known connection implementations
        var impls: std.ArrayList(net.ConnectionImplementation) = .empty;
        defer impls.deinit(allocator);
        if (build_options.openvpn) {
            if (openvpn.impl.connection) |impl| {
                try impls.append(allocator, impl);
            }
        }
        if (build_options.wireguard) {
            if (wireguard.impl.connection) |impl| {
                try impls.append(allocator, impl);
            }
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
            options.profile,
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
                    .cancels_unrecoverable = true,
                    .min_data_count_delta = options.min_data_count_delta,
                    .events = self.events.interface(),
                },
            },
        );
        errdefer self.daemon.deinit(allocator);

        // Bind the platform to the underlying OS callbacks
        self.platform.attach();

        self.options = options;
        self.bindings = if (bindings) |b| b.* else null;
        return self;
    }

    pub fn deinit(self: *DaemonRuntime, allocator: std.mem.Allocator) void {
        self.daemon.deinit(allocator);
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

    pub fn start(self: *DaemonRuntime, allocator: std.mem.Allocator) RuntimeError!void {
        return try self.daemon.start(allocator);
    }

    pub fn hold(self: *DaemonRuntime) void {
        self.daemon.hold();
    }

    pub fn stop(self: *DaemonRuntime) void {
        self.daemon.stop();
    }
};
