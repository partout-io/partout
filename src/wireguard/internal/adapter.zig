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
const passive_io = @import("passive_io.zig");
const resolver = @import("resolver.zig");
const tunnel_info = @import("tunnel_info.zig");
const uapi = @import("uapi.zig");

const PassiveIO = passive_io.PassiveIO;
const PeerEndpointResolver = resolver.PeerEndpointResolver;
const TunnelRemoteInfoBuilder = tunnel_info.TunnelRemoteInfoBuilder;

/// Selects network-change semantics independently of the platform name.
///
/// One environment keeps wg-go alive while its sockets are replaced;
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
    last_reachable: bool = false,
    transport: Transport,

    pub const default_daemon_io: net.Connection.DaemonIO = if (builtin.os.tag == .windows) .link else .none;

    /// Owns mode-specific resources; State tracks their lifecycle.
    const Transport = union(enum) {
        active: struct {
            controller: net.TunnelController,
            /// Owned while started, temporarily shut down, or awaiting recommit.
            tunnel: net.TunDescriptor = undefined,
        },
        passive: struct {
            start: impl.StartTunnelPassive = undefined,
            io: PassiveIO,
        },
    };

    /// Concrete failures produced while activating the WireGuard tunnel.
    /// The connection preserves allocator failures and logs/erases the
    /// WireGuard-specific failures to `UnableToStart` at the generic boundary.
    pub const ActivationError = BuildConfigurationError || TunnelRemoteInfoBuilder.Error || StartBackendError;

    const NetworkChangeResult = union(enum) {
        unchanged,
        needs_rebind: ?api.TunnelRemoteInfoWrapper,
        retry: ActivationError,
    };

    const BuildConfigurationError = resolver.ResolutionError || uapi.BuildConfigurationError;
    const StartBackendError = impl.Error || net.TunnelController.Error || error{CouldNotStartBackend};

    const State = union(enum) {
        /// No backend or temporary-restart work is active.
        stopped,

        /// Active startup has prepared DNS and is waiting for its first TUN.
        awaiting_commit,

        /// wg-go is running with this opaque backend handle.
        started: i32,

        /// The device went offline, so wg-go was torn down while the tunnel
        /// configuration remains available for a fresh DNS resolution/restart.
        temporary_shutdown,

        /// Active resume retains the old TUN while awaiting its replacement.
        recommitting,
    };

    const ConfigurationScope = enum {
        full,
        endpoints,
    };

    pub fn init(
        module_id: api.UUID,
        backend: impl.Backend,
        daemon_io: net.Connection.DaemonIO,
        controller: net.TunnelController,
        dns_resolver: net.DNSResolver,
        factory: net.SocketFactory,
        profile: *const api.Profile,
        configuration: *const api.WireGuardConfiguration,
        dns_timeout_ms: u32,
    ) std.mem.Allocator.Error!WireGuardAdapter {
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
            .transport = switch (daemon_io) {
                .none => .{ .active = .{ .controller = controller } },
                .link => .{ .passive = .{ .io = try PassiveIO.init(backend.vtable.complete_io orelse @panic("complete_io undefined in backend")) } },
                .looper => @panic("WireGuard requires link or none daemon I/O"),
            },
        };
    }

    pub fn deinit(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        log.write(.debug, "Deinit WireGuardAdapter");
        self.stop(allocator);
        switch (self.transport) {
            .active => {},
            .passive => |*passive| passive.io.deinit(),
        }
        self.endpoint_resolver.deinit(allocator);
    }

    /// Takes link ownership on entry. Returns owned tunnel info for a new start,
    /// or null when only replacing the link of an already active adapter.
    pub fn start(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        remote: net.RemoteDescriptor,
    ) ActivationError!?api.TunnelRemoteInfoWrapper {
        self.replaceLink(remote);
        errdefer self.stop(allocator);
        if (!self.isStopped()) {
            log.write(.debug, "Replaced link, adapter is already active");
            return null;
        }

        var info = try self.buildTunnelInfo(allocator);
        errdefer info.deinit(allocator);

        log.writef(.info, "Start {s} adapter", .{@tagName(self.transport)});
        switch (self.transport) {
            .active => {
                // Cache hostnames before the daemon applies tunnel settings.
                try self.endpoint_resolver.cacheAll(allocator);
                self.state = .awaiting_commit;
            },
            .passive => |*passive| {
                passive.start = passive.io.transport(remote.local_port, TunnelRemoteInfoBuilder.effectiveMTU(info));
                try self.activate(allocator);
            },
        }
        return info;
    }

    /// Takes TUN ownership on entry; a suspended backend stays retryable on failure.
    pub fn commit(self: *WireGuardAdapter, allocator: std.mem.Allocator, descriptor: net.TunDescriptor) ActivationError!void {
        var incoming = descriptor;
        errdefer incoming.cleanup();
        switch (self.transport) {
            .active => |*active| {
                switch (self.state) {
                    .awaiting_commit => {
                        active.tunnel = descriptor;
                        try self.activate(allocator);
                    },
                    .recommitting => {
                        if (!self.last_reachable) return error.CouldNotStartBackend;
                        var previous = active.tunnel;
                        active.tunnel = descriptor;
                        errdefer active.tunnel = previous;
                        try self.activate(allocator);
                        previous.cleanup();
                    },
                    else => return error.CouldNotStartBackend,
                }
            },
            .passive => |*passive| passive.io.replaceTun(descriptor),
        }
    }

    /// False means the suspended adapter needs a local retry.
    pub fn rebind(self: *WireGuardAdapter, allocator: std.mem.Allocator, remote: net.RemoteDescriptor, tun: ?net.TunDescriptor) ActivationError!bool {
        self.replaceLink(remote);
        if (tun) |descriptor| self.commit(allocator, descriptor) catch |err| {
            switch (self.transport) {
                .active => {
                    if (self.state != .recommitting) return err;
                    self.state = .temporary_shutdown;
                    log.writef(.err, "Unable to resume WireGuard tunnel: {s}", .{@errorName(err)});
                    return false;
                },
                .passive => return err,
            }
        };
        self.sendKeepalives();
        return true;
    }

    pub fn stop(self: *WireGuardAdapter, allocator: std.mem.Allocator) void {
        if (!self.isStopped()) log.write(.info, "Stop adapter");
        // A prepared active connection can be stopped before commit starts Go.
        const previous = self.state;
        switch (self.state) {
            .started => |handle| {
                self.quiesce();
                self.backend.turnOff(handle);
            },
            .stopped, .awaiting_commit, .temporary_shutdown, .recommitting => {},
        }
        self.state = .stopped;
        self.last_reachable = false;
        self.endpoint_resolver.reset(allocator);
        switch (self.transport) {
            .active => |*active| {
                switch (previous) {
                    .started, .temporary_shutdown, .recommitting => active.tunnel.cleanup(),
                    .stopped, .awaiting_commit => {},
                }
                active.tunnel = undefined;
            },
            .passive => |*passive| passive.io.release(),
        }
    }

    pub fn isStarted(self: *const WireGuardAdapter) bool {
        return self.state == .started;
    }

    pub fn isStopped(self: *const WireGuardAdapter) bool {
        return self.state == .stopped;
    }

    pub fn hasResources(self: *WireGuardAdapter) bool {
        if (!self.isStopped()) return true;
        return switch (self.transport) {
            .active => false,
            .passive => |*passive| passive.io.hasIO(),
        };
    }

    pub fn daemonIO(self: *const WireGuardAdapter) net.Connection.DaemonIO {
        return switch (self.transport) {
            .active => .none,
            .passive => .link,
        };
    }

    pub fn dataCountFromRuntimeConfig(
        self: *const WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) impl.Error!?api.DataCount {
        const handle = switch (self.state) {
            .started => |value| value,
            .stopped, .awaiting_commit, .temporary_shutdown, .recommitting => return null,
        };
        const text = (try self.backend.getConfig(allocator, handle)) orelse return null;
        defer allocator.free(text);
        return uapi.parseRuntimeDataCount(text);
    }

    pub fn setFailureReporter(self: *WireGuardAdapter, ctx: *anyopaque, report: *const fn (*anyopaque) void) void {
        switch (self.transport) {
            .active => {},
            .passive => |*passive| passive.io.failure = .{ .ctx = ctx, .report = report },
        }
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
                    // Retain learned endpoints. Active backends replace their
                    // sockets; passive connections request host replacement.
                    .refresh_sockets => self.refreshSockets(allocator, handle),
                    .suspend_backend_when_offline => if (!is_reachable) {
                        log.write(.debug, "Connectivity offline, pausing backend.");
                        self.state = .temporary_shutdown;
                        self.quiesce();
                        self.backend.turnOff(handle);
                    } else {
                        self.updatePeerEndpoints(allocator, handle);
                    },
                }
                return .unchanged;
            },
            .temporary_shutdown, .recommitting => {
                if (!is_reachable) return .unchanged;
                return self.resumeTemporaryShutdown(allocator);
            },
            .stopped, .awaiting_commit => return .unchanged,
        }
    }

    pub fn prepareLinkRefresh(self: *WireGuardAdapter, info: ?api.TunnelRemoteInfoWrapper, events: net.Connection.Events) void {
        if (info == null and !self.isStarted()) return;
        switch (self.transport) {
            .active => {
                if (info == null or self.state != .temporary_shutdown) return;
                self.state = .recommitting;
            },
            .passive => |*passive| passive.io.releaseLink(),
        }
        events.emit(.{ .needs_rebind = info });
    }

    /// Retries only if no newer reachability event made the pending attempt
    /// stale. Scheduling is owned by the connection so this method always runs
    /// on the daemon actor with the rest of the adapter state machine.
    pub fn retryTemporaryShutdown(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) NetworkChangeResult {
        if (self.state != .temporary_shutdown or !self.last_reachable) return .unchanged;
        return self.resumeTemporaryShutdown(allocator);
    }

    pub fn sendKeepalives(self: *const WireGuardAdapter) void {
        switch (self.state) {
            .started => |handle| self.backend.sendKeepalives(handle),
            .stopped, .awaiting_commit, .temporary_shutdown, .recommitting => {},
        }
    }

    fn buildTunnelInfo(self: *const WireGuardAdapter, allocator: std.mem.Allocator) TunnelRemoteInfoBuilder.Error!api.TunnelRemoteInfoWrapper {
        return TunnelRemoteInfoBuilder.init(allocator, self.profile, self.module_id, self.configuration).build();
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

    fn startBackend(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
        wg_config: [:0]const u8,
    ) StartBackendError!i32 {
        log.writef(.debug, "Start {s} wg-go backend", .{@tagName(self.transport)});
        const handle = (switch (self.transport) {
            .active => |active| self.backend.turnOn(allocator, wg_config, .{
                .tun = active.tunnel.tunWrapper() orelse return error.CannotLocateTunnelFileDescriptor,
                .ifname = self.module_id[0..],
            }),
            .passive => |*passive| blk: {
                passive.io.activate();
                break :blk self.backend.turnOnPassive(allocator, wg_config, passive.start);
            },
        }) catch |err| {
            log.writef(.err, "Starting tunnel failed: {s}", .{@errorName(err)});
            return err;
        };
        if (handle < 0) {
            log.writef(.err, "Starting tunnel failed with backend returning {d}", .{handle});
            return error.CouldNotStartBackend;
        }
        log.writef(.debug, "wg-go backend started with handle {d}", .{handle});
        errdefer self.backend.turnOff(handle);

        if (builtin.os.tag == .ios) {
            self.backend.disableRoaming(handle);
        }
        try self.configureSockets(allocator, handle);
        return handle;
    }

    fn configureSockets(self: *const WireGuardAdapter, allocator: std.mem.Allocator, handle: i32) StartBackendError!void {
        if (self.transport != .active) return;
        const descriptors = try self.backend.socketDescriptors(allocator, handle);
        defer allocator.free(descriptors);
        if (descriptors.len > 0) try self.transport.active.controller.configureSockets(descriptors);
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
        self.refreshSockets(allocator, handle);
    }

    fn refreshSockets(self: *const WireGuardAdapter, allocator: std.mem.Allocator, handle: i32) void {
        if (self.transport != .active) return;
        self.backend.bumpSockets(handle, true);
        self.configureSockets(allocator, handle) catch |err| {
            log.writef(.err, "Unable to update reachability: {s}", .{@errorName(err)});
        };
    }

    fn resumeTemporaryShutdown(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) NetworkChangeResult {
        return self.resumeBackend(allocator) catch |err| {
            // Restart failure is transient state-machine work, not a new
            // terminal connection error. Swift logs it and retries while the
            // latest reachability state remains up. The error is also surfaced
            // to the connection for retry scheduling.
            log.writef(.err, "Failed to restart backend: {s}", .{@errorName(err)});
            return .{ .retry = err };
        };
    }

    fn resumeBackend(
        self: *WireGuardAdapter,
        allocator: std.mem.Allocator,
    ) ActivationError!NetworkChangeResult {
        log.write(.debug, "Connectivity online, resuming backend.");
        // Preserve prepared DNS until the pending TUN handoff completes.
        if (self.state == .recommitting) return .unchanged;
        // Do not carry endpoint answers across an offline interval. Both the
        // hostname's A/AAAA set and the active network's DNS64 prefix may have
        // changed while the backend was down.
        self.endpoint_resolver.reset(allocator);
        switch (self.transport) {
            .active => {
                try self.endpoint_resolver.cacheAll(allocator);
                return .{ .needs_rebind = try self.buildTunnelInfo(allocator) };
            },
            .passive => {
                try self.activate(allocator);
                return .{ .needs_rebind = null };
            },
        }
    }

    fn replaceLink(self: *WireGuardAdapter, remote: net.RemoteDescriptor) void {
        switch (self.transport) {
            .active => {},
            .passive => |*passive| passive.io.replaceLink(remote.link orelse @panic("WireGuard requires a link descriptor")),
        }
    }

    fn quiesce(self: *WireGuardAdapter) void {
        switch (self.transport) {
            .active => {},
            .passive => |*passive| passive.io.quiesce(),
        }
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
