// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const api = core.api;
const log = core.logging;

const impl = @import("backend.zig");
const resolver = @import("resolver.zig");
const uapi = @import("uapi.zig");

const PeerEndpointResolver = resolver.PeerEndpointResolver;

/// Selects network-change semantics independently of the platform name.
///
/// One environment keeps wg-go alive while the host replaces sockets;
/// another recreates the backend once a usable network is available.
const NetworkChangeBehavior = enum {
    refresh_sockets,
    suspend_backend_when_offline,

    fn current() NetworkChangeBehavior {
        return if (builtin.os.tag == .macos)
            .refresh_sockets
        else
            .suspend_backend_when_offline;
    }
};

pub const WireGuardAdapter = struct {
    module_id: api.UUID,
    backend: impl.Backend,
    profile: *const api.Profile,
    configuration: *const api.WireGuardConfiguration,
    endpoint_resolver: PeerEndpointResolver,
    network_change_behavior: NetworkChangeBehavior,
    state: State = .stopped,
    /// Latest reachability event, used only to gate background restart retries.
    last_reachable: ?bool = null,
    transport: impl.StartTunnelPassive = undefined,

    /// Concrete failures produced while activating the WireGuard tunnel.
    /// The connection preserves allocator failures and logs/erases the
    /// WireGuard-specific failures to `UnableToStart` at the generic boundary.
    pub const ActivationError = BuildConfigurationError || StartBackendError;

    const NetworkChangeResult = union(enum) {
        unchanged,
        resumed,
        retry: ActivationError,
    };

    const BuildConfigurationError = resolver.ResolutionError || uapi.BuildConfigurationError;
    const StartBackendError = impl.Error || error{CouldNotStartBackend};

    const State = union(enum) {
        /// No backend or temporary-restart work is active.
        stopped,

        /// wg-go is running with this opaque backend handle.
        started: i32,

        /// The device went offline, so wg-go was torn down while the tunnel
        /// configuration remains available for a fresh DNS resolution/restart.
        temporary_shutdown,
    };

    const ConfigurationScope = enum {
        full,
        endpoints,
    };

    pub fn init(
        module_id: api.UUID,
        backend: impl.Backend,
        dns_resolver: net.DNSResolver,
        factory: net.SocketFactory,
        profile: *const api.Profile,
        configuration: *const api.WireGuardConfiguration,
        dns_timeout_ms: u32,
    ) WireGuardAdapter {
        return .{
            .module_id = module_id,
            .backend = backend,
            .profile = profile,
            .configuration = configuration,
            .endpoint_resolver = PeerEndpointResolver.init(
                configuration.peers,
                dns_resolver,
                factory,
                dns_timeout_ms,
            ),
            .network_change_behavior = .current(),
        };
    }

    pub fn deinit(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        log.write(.debug, "Deinit WireGuardAdapter v2");
        self.stop(allocator);
        self.endpoint_resolver.deinit(allocator);
    }

    pub fn start(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        transport: impl.StartTunnelPassive,
    ) ActivationError!void {
        if (!self.isStopped())
            @panic("WireGuardAdapter.start() requires a stopped adapter");
        self.transport = transport;
        errdefer self.shutdown(allocator);

        log.write(.info, "Start passive adapter");
        self.activate(allocator) catch |err| {
            log.writef(.fault, "Unable to start: {s}", .{@errorName(err)});
            return err;
        };
    }

    pub fn stop(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        if (self.isStopped()) return;
        log.write(.info, "Stop adapter");
        self.shutdown(allocator);
    }

    pub fn isStopped(self: *const WireGuardAdapter) bool {
        return switch (self.state) {
            .stopped => true,
            .started, .temporary_shutdown => false,
        };
    }

    fn activate(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) ActivationError!void {
        try self.endpoint_resolver.cacheAll(allocator);

        const wg_config = try buildConfiguration(
            allocator,
            self.configuration,
            &self.endpoint_resolver,
            .full,
        );
        defer allocator.free(wg_config);

        const handle = try self.startBackend(allocator, wg_config);
        self.state = .{ .started = handle };
    }

    pub fn interfaceName(_: *const WireGuardAdapter) ?[]const u8 {
        // The passive backend owns no native interface.
        return null;
    }

    fn startBackend(
        self: *const WireGuardAdapter,
        allocator: std.mem.Allocator,
        wg_config: [:0]const u8,
    ) StartBackendError!i32 {
        log.write(.debug, "Start passive wg-go backend");
        const handle = self.backend.turnOnPassive(allocator, wg_config, self.transport) catch |err| {
            log.writef(.err, "Starting tunnel failed: {s}", .{@errorName(err)});
            return err;
        };
        if (handle < 0) {
            log.writef(.err, "Starting tunnel failed with wgTurnOnPassive returning {d}", .{handle});
            return error.CouldNotStartBackend;
        }
        log.writef(.debug, "wg-go backend started with handle {d}", .{handle});

        if (builtin.os.tag == .ios) {
            self.backend.disableRoaming(handle);
        }
        return handle;
    }

    pub fn didUpdateReachable(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        is_reachable: bool,
    ) NetworkChangeResult {
        log.writef(.debug, "Network change detected, reachable: {}", .{is_reachable});
        self.last_reachable = is_reachable;

        switch (self.state) {
            .started => |handle| {
                switch (self.network_change_behavior) {
                    .refresh_sockets => {
                        // The host owns socket replacement; Go only updates peers.
                        self.updatePeerEndpoints(allocator, handle);
                    },
                    .suspend_backend_when_offline => if (!is_reachable) {
                        log.write(.debug, "Connectivity offline, pausing backend.");
                        self.state = .temporary_shutdown;
                        self.backend.turnOff(handle);
                    } else {
                        self.updatePeerEndpoints(allocator, handle);
                    },
                }
                return .unchanged;
            },
            .temporary_shutdown => {
                if (!is_reachable) return .unchanged;
                return self.resumeTemporaryShutdown(allocator);
            },
            .stopped => return .unchanged,
        }
    }

    fn updatePeerEndpoints(self: *WireGuardAdapter, allocator: std.mem.Allocator, handle: i32) void {
        // A live path change keeps the cached IPv4 bases and rebuilds only the
        // endpoint UAPI. The DNS resolver may remap them against the current
        // DNS64 prefix; hostname lookup is reserved for an offline restart.
        const wg_config = buildConfiguration(
            allocator,
            self.configuration,
            &self.endpoint_resolver,
            .endpoints,
        ) catch |err| {
            log.writef(.err, "Unable to resolve peer endpoints: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(wg_config);
        if (wg_config.len > 0) {
            _ = self.backend.setConfig(allocator, handle, wg_config) catch |err| {
                log.writef(.err, "Unable to update peer endpoints: {s}", .{@errorName(err)});
                return;
            };
        }
        // Swift reapplies this wg-go workaround after every live endpoint
        // update under the suspend-while-offline policy. `setConfig` can
        // otherwise restore roaming behavior that is unreliable there.
        self.backend.disableRoaming(handle);
    }

    fn resumeTemporaryShutdown(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) NetworkChangeResult {
        self.resumeBackend(allocator) catch |err| {
            // Restart failure is transient state-machine work, not a new
            // terminal connection error. Swift logs it and retries while the
            // latest reachability state remains up. The error is also surfaced
            // to the connection for retry scheduling.
            log.writef(.err, "Failed to restart backend: {s}", .{@errorName(err)});
            return .{ .retry = err };
        };
        return .resumed;
    }

    fn resumeBackend(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) ActivationError!void {
        log.write(.debug, "Connectivity online, resuming backend.");
        // Do not carry endpoint answers across an offline interval. Both the
        // hostname's A/AAAA set and the active network's DNS64 prefix may have
        // changed while the backend was down.
        self.endpoint_resolver.reset(allocator);
        try self.activate(allocator);
    }

    /// Retries only if no newer reachability event made the pending attempt
    /// stale. Scheduling is owned by the connection so this method always runs
    /// on the daemon actor with the rest of the adapter state machine.
    pub fn retryTemporaryShutdown(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) NetworkChangeResult {
        if (!self.shouldRetryTemporaryShutdown()) return .unchanged;
        return self.resumeTemporaryShutdown(allocator);
    }

    fn shouldRetryTemporaryShutdown(self: *const WireGuardAdapter) bool {
        return self.isTemporarilyShutdown() and (self.last_reachable orelse false);
    }

    fn isTemporarilyShutdown(self: *const WireGuardAdapter) bool {
        return self.state == .temporary_shutdown;
    }

    fn shutdown(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .started => |handle| self.backend.turnOff(handle),
            .stopped, .temporary_shutdown => {},
        }
        self.state = .stopped;
        self.last_reachable = null;
        self.endpoint_resolver.reset(allocator);
    }

    pub fn dataCountFromRuntimeConfig(
        self: *const WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) impl.Error!?api.DataCount {
        const handle = switch (self.state) {
            .started => |value| value,
            .stopped, .temporary_shutdown => return null,
        };
        const text = (try self.backend.getConfig(allocator, handle)) orelse return null;
        defer allocator.free(text);
        return uapi.parseRuntimeDataCount(text);
    }
};

fn buildConfiguration(
    allocator: std.mem.Allocator,
    configuration: *const api.WireGuardConfiguration,
    endpoint_resolver: *PeerEndpointResolver,
    scope: WireGuardAdapter.ConfigurationScope,
) WireGuardAdapter.BuildConfigurationError![:0]u8 {
    const resolved_endpoints = try endpoint_resolver.resolve(
        allocator,
        std.EnumSet(net.DNSResolver.Flag).initEmpty(),
    );
    return switch (scope) {
        .full => uapi.buildConfiguration(allocator, configuration, resolved_endpoints),
        .endpoints => uapi.buildEndpointConfiguration(allocator, configuration, resolved_endpoints),
    };
}

pub const testing = struct {
    pub fn setNetworkChangeBehavior(
        adapter: *WireGuardAdapter,
        behavior: NetworkChangeBehavior,
    ) void {
        adapter.network_change_behavior = behavior;
    }

    pub fn buildUapiConfiguration(
        allocator: std.mem.Allocator,
        configuration: *const api.WireGuardConfiguration,
        dns_resolver: net.DNSResolver,
    ) WireGuardAdapter.BuildConfigurationError![:0]u8 {
        var endpoint_resolver = PeerEndpointResolver.init(
            configuration.peers,
            dns_resolver,
            null,
            (net.ConnectionOptions{}).dns_timeout,
        );
        defer endpoint_resolver.deinit(allocator);

        try endpoint_resolver.cacheAll(allocator);
        return buildConfiguration(allocator, configuration, &endpoint_resolver, .full);
    }
};
