// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const api = core.api;
const log = core.logging;

const impl = @import("backend.zig");
const resolver = @import("resolver.zig");
const tunnel_info = @import("tunnel_info.zig");
const uapi = @import("uapi.zig");

const PeerEndpointResolver = resolver.PeerEndpointResolver;
const TunnelRemoteInfoBuilder = tunnel_info.TunnelRemoteInfoBuilder;

/// Selects network-change semantics independently of the platform name.
///
/// One environment can keep wg-go alive and replace its path-bound sockets;
/// another must recreate the backend once a usable network is available.
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

const NetworkChangeResult = enum {
    unchanged,
    resumed,
    retry,
};

pub const WireGuardAdapter = struct {
    module_id: api.UUID,
    backend: impl.Backend,
    controller: net.TunnelController,
    profile: *const api.Profile,
    configuration: *const api.WireGuardConfiguration,
    endpoint_resolver: PeerEndpointResolver,
    network_change_behavior: NetworkChangeBehavior,
    state: State = .stopped,
    /// Latest reachability event, used only to gate background restart retries.
    last_reachable: ?bool = null,
    tunnel: ?net.TunWrapper = null,

    /// Concrete failures produced while activating the WireGuard tunnel.
    /// The connection logs these locally before exposing only the generic
    /// `UnableToStart` error through `net.Connection`.
    pub const ActivationError = BuildConfigurationError ||
        TunnelRemoteInfoBuilder.Error ||
        net.TunnelController.Error ||
        StartBackendError;

    const BuildConfigurationError = resolver.ResolutionError || uapi.BuildConfigurationError;
    const ConfigureSocketsError = impl.Error || net.TunnelController.Error;
    const StartBackendError = ConfigureSocketsError || error{CouldNotStartBackend};

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
        controller: net.TunnelController,
        dns_resolver: net.DNSResolver,
        factory: net.SocketFactory,
        profile: *const api.Profile,
        configuration: *const api.WireGuardConfiguration,
        dns_timeout_ms: u32,
    ) WireGuardAdapter {
        return .{
            .module_id = module_id,
            .backend = backend,
            .controller = controller,
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
        self.stop(allocator);
        self.endpoint_resolver.deinit(allocator);
    }

    pub fn start(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) ActivationError!void {
        std.debug.assert(self.isStopped());
        errdefer self.shutdown(allocator);

        log.write(.info, "WireGuard: Start adapter");
        try self.activate(allocator);
        log.write(.info, "WireGuard: Tunnel connected");
    }

    pub fn stop(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        if (self.isStopped()) return;
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

        var remote_info = try TunnelRemoteInfoBuilder.init(
            allocator,
            self.profile,
            self.module_id,
            self.configuration,
        ).build();
        defer remote_info.deinit(allocator);
        try self.setNetworkSettings(remote_info);

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

    fn setNetworkSettings(
        self: *WireGuardAdapter,
        remote_info: api.TunnelRemoteInfoWrapper,
    ) net.TunnelController.Error!void {
        log.write(.debug, "WireGuard: Configure tunnel settings");
        const new_tunnel = self.controller.setTunnelSettings(remote_info) catch |err| {
            log.writef(.err, "WireGuard: Unable to configure tunnel settings: {}", .{err});
            return err;
        };

        // The new settings should produce a new tun interface
        if (self.tunnel) |*old_tunnel| {
            old_tunnel.deinit();
        }
        self.tunnel = new_tunnel;
        if (self.tunnel == null) {
            // This is expected on Windows: wg-go opens the adapter itself by
            // the interface name passed to `turnOn`. Other controllers may
            // still omit a native descriptor when no socket setup is needed.
            log.write(.debug, "WireGuard: Tunnel controller did not return a native TUN");
            return;
        }

        // Not all platforms supply an interface name for tun
        if (self.interfaceName()) |name| {
            log.writef(.info, "WireGuard: Tunnel interface is now UP ({s})", .{name});
        } else {
            log.write(.info, "WireGuard: Tunnel interface is now UP");
        }
    }

    fn interfaceName(self: *const WireGuardAdapter) ?[]const u8 {
        const tunnel = self.tunnel orelse return null;
        if (tunnel.tun == null) return null;
        return tunnel.name();
    }

    fn startBackend(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        wg_config: []const u8,
    ) StartBackendError!i32 {
        log.write(.debug, "WireGuard: Start wg-go backend");
        const handle = self.backend.turnOn(allocator, wg_config, .{
            .tun = self.tunnel,
            .ifname = self.module_id[0..],
        }) catch |err| {
            log.writef(.err, "WireGuard: Starting tunnel failed: {}", .{err});
            return err;
        };
        if (handle < 0) {
            log.writef(.err, "WireGuard: Starting tunnel failed with wgTurnOn returning {}", .{handle});
            return error.CouldNotStartBackend;
        }
        log.writef(.debug, "WireGuard: wg-go backend started with handle {}", .{handle});
        errdefer self.backend.turnOff(handle);

        if (builtin.os.tag == .ios) {
            self.backend.disableRoaming(handle);
        }
        try self.configureSockets(allocator, handle);
        return handle;
    }

    fn configureSockets(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        handle: i32,
    ) ConfigureSocketsError!void {
        const descriptors = self.backend.socketDescriptors(allocator, handle) catch |err| {
            log.writef(.err, "WireGuard: Unable to fetch backend socket descriptors: {}", .{err});
            return err;
        };
        defer allocator.free(descriptors);

        if (descriptors.len == 0) {
            if (builtin.abi.isAndroid()) {
                log.write(.fault, "WireGuard: Socket descriptors are empty");
            } else {
                log.write(.debug, "WireGuard: Backend returned no sockets to configure");
            }
            return;
        }
        log.writef(.info, "WireGuard: Configure {} backend sockets", .{descriptors.len});
        self.controller.configureSockets(descriptors) catch |err| {
            log.writef(.err, "WireGuard: Unable to configure backend sockets: {}", .{err});
            return err;
        };
    }

    pub fn didUpdateReachable(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        is_reachable: bool,
    ) NetworkChangeResult {
        log.writef(.debug, "WireGuard: Network change detected, reachable: {}", .{is_reachable});
        self.last_reachable = is_reachable;

        switch (self.state) {
            .started => |handle| {
                switch (self.network_change_behavior) {
                    .refresh_sockets => {
                        // The backend remains live even for an unreachable path
                        // notification. Bumping makes wg-go discard path-bound
                        // sockets; the replacements are then protected again.
                        self.refreshSockets(allocator, handle);
                    },
                    .suspend_backend_when_offline => if (!is_reachable) {
                        log.write(.debug, "WireGuard: Connectivity offline, pausing backend");
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
            log.writef(.err, "WireGuard: Unable to build peer endpoint update: {}", .{err});
            return;
        };
        defer allocator.free(wg_config);
        if (wg_config.len > 0) {
            _ = self.backend.setConfig(allocator, handle, wg_config) catch |err| {
                log.writef(.err, "WireGuard: Unable to update peer endpoints: {}", .{err});
                return;
            };
        }
        // Swift reapplies this wg-go workaround after every live endpoint
        // update under the suspend-while-offline policy. `setConfig` can
        // otherwise restore roaming behavior that is unreliable there.
        self.backend.disableRoaming(handle);
        self.refreshSockets(allocator, handle);
    }

    fn refreshSockets(self: *WireGuardAdapter, allocator: std.mem.Allocator, handle: i32) void {
        self.backend.bumpSockets(handle, true);
        self.configureSockets(allocator, handle) catch |err| {
            log.writef(.err, "WireGuard: Unable to configure sockets after network change: {}", .{err});
        };
    }

    fn resumeTemporaryShutdown(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) NetworkChangeResult {
        self.resumeBackend(allocator) catch |err| {
            // Restart failure is transient state-machine work, not a new
            // connection error. Swift logs it and retries while the latest
            // reachability state remains up.
            log.writef(.err, "WireGuard: Failed to restart backend: {}", .{err});
            return .retry;
        };
        return .resumed;
    }

    fn resumeBackend(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) ActivationError!void {
        log.write(.debug, "WireGuard: Connectivity online, resuming backend");
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
        self.clearTunnel();
    }

    fn clearTunnel(self: *WireGuardAdapter) void {
        if (self.tunnel) |*tun| {
            tun.deinit();
            self.tunnel = null;
        }
        self.controller.clearTunnelSettings(false);
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
) WireGuardAdapter.BuildConfigurationError![]u8 {
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
    ) WireGuardAdapter.BuildConfigurationError![]u8 {
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
