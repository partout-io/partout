// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const api = core.api;
const log = core.logging;

const adapter_mod = @import("adapter.zig");
const impl = @import("backend.zig");

const WireGuardAdapter = adapter_mod.WireGuardAdapter;

pub fn createConnection(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net.ConnectionModule,
    sandbox: net.Sandbox,
) net.ConnectionCreateError!net.Connection {
    const raw = ptr orelse return error.MissingConnectionImplementation;
    const ctx: *const ConnectionContext = @ptrCast(@alignCast(raw));
    return WireGuardConnection.create(
        allocator,
        ctx.backend,
        module,
        sandbox,
    );
}

pub const ConnectionContext = struct {
    backend: impl.Backend,

    pub fn init(backend: impl.Backend) ConnectionContext {
        return .{
            .backend = backend,
        };
    }
};

const WireGuardConnection = struct {
    allocator: std.mem.Allocator,
    adapter: WireGuardAdapter,
    /// Owns the profile-expanded clone referenced by the adapter.
    configuration: api.WireGuardConfiguration,
    /// Actor-owned event sink used only by serialized connection work.
    events: ?net.Connection.Events = null,
    /// Daemon-owned sandbox capability captured once at creation. Timer threads
    /// use it to enqueue work without retaining or inspecting the unrelated
    /// connection event callbacks.
    serialized_executor: net.SerializedExecutor,
    data_count_timer: core.RunAfter = .{},
    data_count_timer_active: bool = false,
    data_count_interval_ms: u32,
    temporary_shutdown_retry_timer: core.RunAfter = .{},
    temporary_shutdown_retry_delay_ms: u32 = 2000,

    fn create(
        allocator: std.mem.Allocator,
        backend: impl.Backend,
        module: net.ConnectionModule,
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        // ZIGME: Make Configuration non-optional in OpenAPI and remove .IncompleteModule
        const base_configuration = switch (module.module.*) {
            .WireGuard => |*wireguard| blk: {
                const configuration = if (wireguard.configuration) |*value|
                    value
                else
                    return error.IncompleteModule;
                break :blk configuration;
            },
            else => unreachable,
        };

        const created = try allocator.create(WireGuardConnection);
        errdefer allocator.destroy(created);

        const module_id = module.id();
        var configuration = try configurationApplyingActiveModules(
            allocator,
            base_configuration,
            sandbox.profile,
        );
        errdefer configuration.deinit(allocator);

        created.* = .{
            .allocator = allocator,
            .adapter = undefined,
            .configuration = configuration,
            .serialized_executor = sandbox.serialized_executor,
            .data_count_interval_ms = sandbox.options.min_data_count_interval,
        };
        created.adapter = WireGuardAdapter.init(
            module_id,
            backend,
            sandbox.controller,
            sandbox.resolver,
            sandbox.factory,
            sandbox.profile,
            &created.configuration,
            sandbox.options.dns_timeout,
        );
        log.writef(.notice, "WireGuard: Using v2-style connection for module {s}", .{module_id[0..]});
        return created.asConnection();
    }

    fn deinit(self: *WireGuardConnection) void {
        const allocator = self.allocator;
        log.write(.debug, "WireGuard: Deinit connection");
        self.stopDataCountTimer();
        self.cancelTemporaryShutdownRetry();
        self.data_count_timer.deinit();
        self.temporary_shutdown_retry_timer.deinit();
        self.adapter.deinit(allocator);
        self.configuration.deinit(allocator);
        allocator.destroy(self);
    }

    fn asConnection(self: *WireGuardConnection) net.Connection {
        return .{
            .ptr = self,
            .vtable = &wireguard_connection_vtable,
        };
    }

    fn start(
        self: *WireGuardConnection,
        allocator: std.mem.Allocator,
        events: net.Connection.Events,
    ) net.ConnectionStartError!bool {
        if (!self.adapter.isStopped()) {
            log.write(.debug, "WireGuard: Start ignored, adapter is already active");
            return false;
        }

        log.write(.info, "WireGuard: Start tunnel");
        self.events = events;
        events.status(events.ctx, .connecting);
        errdefer events.status(events.ctx, .disconnected);

        self.adapter.start(allocator) catch |err| {
            // Adapter activation errors are the local diagnostic signal. The
            // generic connection contract deliberately exposes no WireGuard-
            // specific categories, so log the concrete error before erasing it.
            log.writef(.fault, "WireGuard: Unable to start adapter: {}", .{err});
            return error.UnableToStart;
        };
        events.status(events.ctx, .connected);
        self.reportDataCount(allocator, events);
        self.startDataCountTimer() catch |err| {
            log.writef(.err, "WireGuard: Unable to start data count timer: {}", .{err});
        };
        return true;
    }

    fn stop(
        self: *WireGuardConnection,
        allocator: std.mem.Allocator,
        timeout_ms: u32,
        events: net.Connection.Events,
    ) void {
        // Match Swift: wg-go shutdown is normally immediate, so the generic
        // connection timeout has nothing useful to interrupt here.
        _ = timeout_ms;
        if (self.adapter.isStopped()) {
            log.write(.debug, "WireGuard: Stop ignored, adapter is stopped");
            return;
        }

        log.write(.info, "WireGuard: Stop tunnel");
        self.stopDataCountTimer();
        self.cancelTemporaryShutdownRetry();
        events.status(events.ctx, .disconnecting);
        self.adapter.stop(allocator);
        events.status(events.ctx, .disconnected);
        log.write(.info, "WireGuard: Tunnel disconnected");
    }

    fn networkChange(
        self: *WireGuardConnection,
        allocator: std.mem.Allocator,
        reachability: net.ReachabilityInfo,
        events: net.Connection.Events,
    ) void {
        self.cancelTemporaryShutdownRetry();
        switch (self.adapter.didUpdateReachable(allocator, reachability.reachable)) {
            .unchanged => {},
            .resumed => events.status(events.ctx, .connected),
            .retry => self.scheduleTemporaryShutdownRetry(),
        }
    }

    fn betterPath(
        _: *WireGuardConnection,
        _: std.mem.Allocator,
        _: net.Connection.Events,
    ) void {
        log.write(.debug, "WireGuard: Better path notification ignored");
    }

    fn reportDataCount(
        self: *const WireGuardConnection,
        allocator: std.mem.Allocator,
        events: net.Connection.Events,
    ) void {
        events.data_count(events.ctx, self.readDataCount(allocator) orelse return);
    }

    fn readDataCount(
        self: *const WireGuardConnection,
        allocator: std.mem.Allocator,
    ) ?api.DataCount {
        return self.adapter.dataCountFromRuntimeConfig(allocator) catch |err| {
            log.writef(.debug, "WireGuard: Unable to fetch runtime configuration: {}", .{err});
            return null;
        };
    }

    fn startDataCountTimer(self: *WireGuardConnection) std.Thread.SpawnError!void {
        self.data_count_timer_active = true;
        self.data_count_timer.init(self.data_count_interval_ms, onDataCountTimer, self) catch |err| {
            self.data_count_timer_active = false;
            return err;
        };
    }

    fn stopDataCountTimer(self: *WireGuardConnection) void {
        self.data_count_timer_active = false;
        self.data_count_timer.cancel();
        // The raw callback only posts asynchronously, so waiting cannot
        // deadlock with the daemon actor. Once drained, a later start cannot
        // inherit a callback from the previous timer generation.
        self.data_count_timer.wait();
    }

    fn onDataCountTimer(ctx: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx.?));
        self.serialized_executor.run(self, onDataCountTask);
    }

    fn onDataCountTask(ctx: *anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx));
        if (!self.data_count_timer_active) return;
        const events = self.events orelse return;

        self.reportDataCount(self.allocator, events);
        if (!self.data_count_timer_active) return;
        self.data_count_timer.init(self.data_count_interval_ms, onDataCountTimer, self) catch |err| {
            log.writef(.err, "WireGuard: Unable to reschedule data count timer: {}", .{err});
            self.data_count_timer_active = false;
        };
    }

    fn scheduleTemporaryShutdownRetry(self: *WireGuardConnection) void {
        // `.retry` is an authoritative adapter outcome. The connection owns
        // when to retry and does not inspect the adapter's internal state.
        log.writef(.debug, "WireGuard: Retry backend restart in {} milliseconds", .{
            self.temporary_shutdown_retry_delay_ms,
        });
        self.temporary_shutdown_retry_timer.init(
            self.temporary_shutdown_retry_delay_ms,
            onTemporaryShutdownRetry,
            self,
        ) catch |err| {
            log.writef(.err, "WireGuard: Unable to schedule backend restart retry: {}", .{err});
        };
    }

    fn cancelTemporaryShutdownRetry(self: *WireGuardConnection) void {
        self.temporary_shutdown_retry_timer.cancel();
        // See stopDataCountTimer(): draining closes the cancellation/startup
        // race without adding synchronization to actor-owned adapter state.
        self.temporary_shutdown_retry_timer.wait();
    }

    fn onTemporaryShutdownRetry(ctx: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx.?));
        self.serialized_executor.run(self, onTemporaryShutdownRetryTask);
    }

    fn onTemporaryShutdownRetryTask(ctx: *anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx));
        const events = self.events orelse return;
        switch (self.adapter.retryTemporaryShutdown(self.allocator)) {
            .unchanged => {},
            .resumed => events.status(events.ctx, .connected),
            .retry => self.scheduleTemporaryShutdownRetry(),
        }
    }
};

/// Swift's `Configuration.withModules(from:)` folds settings-only modules into
/// WireGuard before building the backend and tunnel configurations. Every peer
/// receives the same extra routes: active IP included routes, plus host routes
/// for DNS servers explicitly marked `routesThroughVPN`.
fn configurationApplyingActiveModules(
    allocator: std.mem.Allocator,
    source: *const api.WireGuardConfiguration,
    profile: *const api.Profile,
) std.mem.Allocator.Error!api.WireGuardConfiguration {
    var configuration = source.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson, error.InvalidModel, error.UnsupportedModel => unreachable,
    };
    errdefer configuration.deinit(allocator);

    const peers = @constCast(configuration.peers);
    for (peers) |*peer| try appendActiveModuleAllowedIPs(allocator, peer, profile);
    return configuration;
}

fn appendActiveModuleAllowedIPs(
    allocator: std.mem.Allocator,
    peer: *api.WireGuardRemoteInterface,
    profile: *const api.Profile,
) std.mem.Allocator.Error!void {
    var extra_count: usize = 0;
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .IP => |*ip| {
                if (ip.ipv4) |*settings| extra_count += settings.included_routes.len;
                if (ip.ipv6) |*settings| extra_count += settings.included_routes.len;
            },
            else => {},
        }
    }
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .DNS => |*dns| if (dns.routes_through_vpn orelse false) {
                for (dns.servers) |server| extra_count += @intFromBool(server.isIPAddress());
            },
            else => {},
        }
    }
    if (extra_count == 0) return;

    const previous = peer.allowed_ips;
    const combined = try allocator.alloc(api.Subnet, previous.len + extra_count);
    var initialized = previous.len;
    errdefer {
        for (combined[previous.len..initialized]) |*subnet| subnet.deinit(allocator);
        allocator.free(combined);
    }
    @memcpy(combined[0..previous.len], previous);

    // Keep the Swift ordering: all active IP routes first (v4 then v6 per
    // module), followed by VPN-routed DNS server host routes.
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .IP => |*ip| {
                if (ip.ipv4) |*settings| for (settings.included_routes) |*route| {
                    combined[initialized] = try cloneRouteDestination(allocator, route, .v4);
                    initialized += 1;
                };
                if (ip.ipv6) |*settings| for (settings.included_routes) |*route| {
                    combined[initialized] = try cloneRouteDestination(allocator, route, .v6);
                    initialized += 1;
                };
            },
            else => {},
        }
    }
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .DNS => |*dns| if (dns.routes_through_vpn orelse false) {
                for (dns.servers) |*server| {
                    if (!server.isIPAddress()) continue;
                    combined[initialized] = try cloneAddressAsHostSubnet(allocator, server);
                    initialized += 1;
                }
            },
            else => {},
        }
    }
    std.debug.assert(initialized == combined.len);

    // The old subnet elements were moved into `combined`; only release their
    // container here so their owned address strings remain live.
    allocator.free(previous);
    peer.allowed_ips = combined;
}

fn cloneRouteDestination(
    allocator: std.mem.Allocator,
    route: *const api.Route,
    family: api.Address.Family,
) std.mem.Allocator.Error!api.Subnet {
    if (route.destination) |*destination| return cloneSubnet(allocator, destination);
    return switch (family) {
        .v4 => (try api.Subnet.parseRawAlloc(allocator, "0.0.0.0/0")).?,
        .v6 => (try api.Subnet.parseRawAlloc(allocator, "::/0")).?,
        .hostname => unreachable,
    };
}

fn cloneAddressAsHostSubnet(
    allocator: std.mem.Allocator,
    address: *const api.Address,
) std.mem.Allocator.Error!api.Subnet {
    return .{
        .address = (try api.Address.parseRawAlloc(allocator, address.raw)).?,
        .prefix_length = switch (address.family) {
            .v4 => 32,
            .v6 => 128,
            .hostname => unreachable,
        },
    };
}

fn cloneSubnet(
    allocator: std.mem.Allocator,
    subnet: *const api.Subnet,
) std.mem.Allocator.Error!api.Subnet {
    return .{
        .address = (try api.Address.parseRawAlloc(allocator, subnet.address.raw)).?,
        .prefix_length = subnet.prefix_length,
    };
}

const wireguard_connection_vtable = net.Connection.VTable{
    .start = start,
    .stop = stop,
    .network_change = networkChange,
    .better_path = betterPath,
    .deinit = deinit,
};

fn start(ptr: *anyopaque, events: net.Connection.Events) net.ConnectionStartError!bool {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    return self.start(self.allocator, events);
}

fn stop(
    ptr: *anyopaque,
    timeout_ms: u32,
    events: net.Connection.Events,
) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.stop(self.allocator, timeout_ms, events);
}

fn networkChange(
    ptr: *anyopaque,
    reachability: net.ReachabilityInfo,
    events: net.Connection.Events,
) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.networkChange(self.allocator, reachability, events);
}

fn betterPath(ptr: *anyopaque, events: net.Connection.Events) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.betterPath(self.allocator, events);
}

fn deinit(ptr: *anyopaque, _: std.mem.Allocator) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.deinit();
}

pub const testing = struct {
    pub fn dataCountIntervalMs(connection: net.Connection) u32 {
        const self: *const WireGuardConnection = @ptrCast(@alignCast(connection.ptr));
        return self.data_count_interval_ms;
    }

    pub fn configurationWithActiveModules(
        allocator: std.mem.Allocator,
        source: *const api.WireGuardConfiguration,
        profile: *const api.Profile,
    ) std.mem.Allocator.Error!api.WireGuardConfiguration {
        return configurationApplyingActiveModules(allocator, source, profile);
    }

    pub fn setTemporaryShutdownRetryDelayMs(connection: net.Connection, delay_ms: u32) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(connection.ptr));
        self.temporary_shutdown_retry_delay_ms = delay_ms;
    }

    pub fn adapter(connection: net.Connection) *WireGuardAdapter {
        const self: *WireGuardConnection = @ptrCast(@alignCast(connection.ptr));
        return &self.adapter;
    }

    pub fn waitForTemporaryShutdownRetry(connection: net.Connection) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(connection.ptr));
        self.temporary_shutdown_retry_timer.wait();
    }
};
