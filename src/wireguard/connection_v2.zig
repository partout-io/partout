// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const api = core.api;
const log = core.logging;

const adapter_mod = @import("internal/adapter_v2.zig");
const impl = @import("internal/backend.zig");
const tunnel_info = @import("internal/tunnel_info.zig");
const passive_io = @import("internal/passive_io.zig");

const WireGuardAdapter = adapter_mod.WireGuardAdapter;
const TunnelRemoteInfoBuilder = tunnel_info.TunnelRemoteInfoBuilder;
const PassiveIO = passive_io.PassiveIO;
const ConnectionError = WireGuardAdapter.ActivationError || std.Thread.SpawnError;

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
    // Owns descriptors; native calls execute directly on Go workers.
    io: PassiveIO,
    /// Owns the profile-expanded clone referenced by the adapter.
    configuration: api.WireGuardConfiguration,
    /// Captured event sink; Go workers also report I/O failures through it.
    events: ?net.Connection.Events,
    /// Daemon-owned sandbox capability captured once at creation. Timer threads
    /// use it to enqueue work without retaining or inspecting the unrelated
    /// connection event callbacks.
    serialized_executor: core.SerializedExecutor,
    data_count_timer: core.RunAfter,
    data_count_timer_active: bool,
    data_count_interval_ms: u32,
    temporary_shutdown_retry_timer: core.RunAfter,
    temporary_shutdown_retry_delay_ms: u32,

    fn create(
        allocator: std.mem.Allocator,
        backend: impl.Backend,
        module: net.ConnectionModule,
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        // FIXME: #525, Make Configuration non-optional in OpenAPI and remove .IncompleteModule
        const base_configuration = switch (module.module.*) {
            .WireGuard => |*wireguard| blk: {
                const configuration = if (wireguard.configuration) |*value|
                    value
                else
                    return error.IncompleteModule;
                break :blk configuration;
            },
            else => return error.MissingConnectionImplementation,
        };

        const complete = backend.vtable.complete_io orelse @panic("complete_io undefined in backend");
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
            .io = try PassiveIO.init(complete),
            .configuration = configuration,
            .events = sandbox.events,
            .serialized_executor = sandbox.serialized_executor,
            .data_count_timer = .{},
            .data_count_timer_active = false,
            .data_count_interval_ms = sandbox.options.min_data_count_interval,
            .temporary_shutdown_retry_timer = .{},
            .temporary_shutdown_retry_delay_ms = 2000,
        };
        created.adapter = WireGuardAdapter.init(
            module_id,
            backend,
            &created.io,
            sandbox.resolver,
            sandbox.factory,
            sandbox.profile,
            &created.configuration,
            sandbox.options.dns_timeout,
        );
        created.io.failure = .{ .ctx = created, .report = onIOFailure };
        log.write(.notice, "Using WireGuardConnection v2");
        return created.asConnection();
    }

    fn destroy(self: *WireGuardConnection) void {
        const allocator = self.allocator;
        log.write(.debug, "Deinit WireGuardConnection v2");
        self.stopDataCountTimer();
        self.cancelTemporaryShutdownRetry();
        self.data_count_timer.deinit();
        self.temporary_shutdown_retry_timer.deinit();
        self.releaseIO();
        self.adapter.deinit(allocator);
        self.io.deinit();
        self.configuration.deinit(allocator);
        allocator.destroy(self);
    }

    fn onIOFailure(raw: *anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(raw));
        const events = self.events orelse return;
        log.write(.err, "WireGuard native I/O failed");
        events.failed(events.ctx, .{
            .err_pair = .{ .code = .ioFailure },
            .disposition = .reconnect,
        });
    }

    fn releaseIO(self: *WireGuardConnection) void {
        self.io.release();
    }

    fn asConnection(self: *WireGuardConnection) net.Connection {
        return .{
            .ptr = self,
            .vtable = &wireguard_connection_vtable,
            .owns_io = true,
            .local_port = @intCast(self.configuration.interface.listen_port orelse 0),
        };
    }

    fn startV2(self: *WireGuardConnection, remote: net.RemoteDescriptor) net.ConnectionStartError!bool {
        self.io.replaceLink(remote.link);
        errdefer self.releaseIO();
        const events = self.events orelse return error.UnableToStart;
        if (!self.adapter.isStopped()) {
            log.write(.debug, "Replaced link, adapter is already active");
            return true;
        }

        log.write(.info, "Start tunnel");

        var info = TunnelRemoteInfoBuilder.init(
            self.allocator,
            self.adapter.profile,
            self.adapter.module_id,
            &self.configuration,
        ).build() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnableToStart,
        };
        defer info.deinit(self.allocator);
        self.adapter.start(self.allocator, self.io.transport(remote.local_port, TunnelRemoteInfoBuilder.effectiveMTU(info))) catch |err| {
            switch (err) {
                error.CannotLocateTunnelFileDescriptor => {
                    log.write(
                        .fault,
                        "Starting tunnel failed: could not determine file descriptor",
                    );
                },
                error.DNSResolutionFailure, error.InvalidEndpoint => {
                    log.write(.fault, "DNS resolution failed");
                },
                error.CouldNotStartBackend => {
                    log.write(.fault, "Starting tunnel backend failed");
                },
                else => {
                    // Adapter activation errors are the local diagnostic signal. The
                    // generic connection contract deliberately exposes no WireGuard-
                    // specific categories, so log the concrete error before erasing it.
                    log.writef(.fault, "Unable to start adapter: {s}", .{@errorName(err)});
                },
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.DNSResolutionFailure => error.DNSResolutionFailure,
                else => error.UnableToStart,
            };
        };
        errdefer self.adapter.stop(self.allocator);
        self.reportDataCount(events);
        self.startDataCountTimer() catch |err| {
            log.writef(.err, "Unable to start data count timer: {s}", .{@errorName(err)});
        };
        events.established(events.ctx, .{ .info = info });
        return true;
    }

    fn commit(self: *WireGuardConnection, descriptor: net.TunDescriptor) void {
        log.write(.info, "Commit WireGuard TUN");
        self.io.replaceTun(descriptor);
    }

    fn stop(
        self: *WireGuardConnection,
        timeout_ms: u32,
        events: net.Connection.Events,
    ) void {
        // Match Swift: wg-go shutdown is normally immediate, so the generic
        // connection timeout has nothing useful to interrupt here.
        _ = timeout_ms;
        const had_state = self.io.hasIO() or !self.adapter.isStopped();
        self.stopDataCountTimer();
        self.cancelTemporaryShutdownRetry();
        self.io.quiesce();
        self.adapter.stop(self.allocator);
        self.releaseIO();
        if (had_state) {
            log.write(.info, "Stop tunnel");
            events.stopped(events.ctx);
        }
    }

    fn networkChange(
        self: *WireGuardConnection,
        reachability: net.ReachabilityInfo,
        events: net.Connection.Events,
    ) net.Connection.NetworkAction {
        self.cancelTemporaryShutdownRetry();
        switch (self.adapter.didUpdateReachable(self.allocator, reachability.reachable)) {
            .unchanged => {},
            // Resuming the backend retains the established connection.
            .resumed => {},
            .retry => |err| {
                self.reportActivationFailure(events, err);
                self.scheduleTemporaryShutdownRetry(events);
            },
        }
        return if (self.adapter.isStarted()) .refresh_link else .none;
    }

    fn betterPath(
        self: *WireGuardConnection,
        _: net.Connection.Events,
    ) net.Connection.NetworkAction {
        return if (self.adapter.isStarted()) .refresh_link else .none;
    }

    fn reportDataCount(
        self: *const WireGuardConnection,
        events: net.Connection.Events,
    ) void {
        events.data_count(events.ctx, self.readDataCount() orelse return);
    }

    fn readDataCount(self: *const WireGuardConnection) ?api.DataCount {
        return self.adapter.dataCountFromRuntimeConfig(self.allocator) catch |err| {
            log.writef(.debug, "Unable to fetch runtime configuration: {s}", .{@errorName(err)});
            return null;
        };
    }

    fn startDataCountTimer(self: *WireGuardConnection) std.Thread.SpawnError!void {
        self.data_count_timer_active = true;
        self.data_count_timer.scheduleReplacing(
            self.data_count_interval_ms,
            onDataCountTimer,
            self,
        ) catch |err| {
            self.data_count_timer_active = false;
            return err;
        };
    }

    fn stopDataCountTimer(self: *WireGuardConnection) void {
        const was_active = self.data_count_timer_active;
        self.data_count_timer_active = false;
        self.data_count_timer.cancel();
        // The raw callback only posts asynchronously, so waiting cannot
        // deadlock with the daemon actor. Once drained, a later start cannot
        // inherit a callback from the previous timer generation.
        self.data_count_timer.wait();
        if (was_active) {
            log.write(.debug, "Cancelled WireGuardConnection.dataCountTimer");
        }
    }

    fn onDataCountTimer(ctx: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx.?));
        self.serialized_executor.run(self, onDataCountTask);
    }

    fn onDataCountTask(ctx: *anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(ctx));
        if (!self.data_count_timer_active) return;
        const events = self.events orelse return;

        self.reportDataCount(events);
        if (!self.data_count_timer_active) return;
        self.data_count_timer.scheduleReplacing(
            self.data_count_interval_ms,
            onDataCountTimer,
            self,
        ) catch |err| {
            log.writef(.err, "Unable to reschedule data count timer: {s}", .{@errorName(err)});
            self.data_count_timer_active = false;
        };
    }

    fn scheduleTemporaryShutdownRetry(
        self: *WireGuardConnection,
        events: net.Connection.Events,
    ) void {
        // `.retry` is an authoritative adapter outcome. The connection owns
        // when to retry and does not inspect the adapter's internal state.
        log.writef(.debug, "Retry backend restart in {} milliseconds", .{
            self.temporary_shutdown_retry_delay_ms,
        });
        self.temporary_shutdown_retry_timer.scheduleReplacing(
            self.temporary_shutdown_retry_delay_ms,
            onTemporaryShutdownRetry,
            self,
        ) catch |err| {
            self.handleTemporaryShutdownRetrySchedulingFailure(events, err);
        };
    }

    fn handleTemporaryShutdownRetrySchedulingFailure(
        _: *WireGuardConnection,
        events: net.Connection.Events,
        err: std.Thread.SpawnError,
    ) void {
        log.writef(.fault, "Unable to schedule backend restart retry: {s}", .{@errorName(err)});

        // The daemon owns shutdown and finalization after a terminal event.
        events.failed(events.ctx, .{
            .err_pair = .{ .code = partoutCodeForError(err) },
            .disposition = .cancel,
        });
    }

    fn reportActivationFailure(
        self: *WireGuardConnection,
        events: net.Connection.Events,
        err: ConnectionError,
    ) void {
        log.writef(.err, "Unable to resume WireGuard backend: {s}", .{@errorName(err)});
        // Transient resume errors retain local retry work. A failure event
        // would make the daemon stop the connection and cancel that retry.
        if (self.adapter.isStopped()) {
            events.failed(events.ctx, .{
                .err_pair = .{ .code = partoutCodeForError(err) },
                .disposition = .reconnect,
            });
        }
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
            .resumed => {},
            .retry => |err| {
                self.reportActivationFailure(events, err);
                self.scheduleTemporaryShutdownRetry(events);
            },
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
) net.ConnectionCreateError!api.WireGuardConfiguration {
    var configuration = source.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson, error.InvalidModel, error.UnsupportedModel => return error.IncompleteModule,
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
) net.ConnectionCreateError!void {
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
                    combined[initialized] = (try api.Subnet.parseRawAlloc(
                        allocator,
                        server.raw,
                    )) orelse return error.IncompleteModule;
                    initialized += 1;
                }
            },
            else => {},
        }
    }
    if (initialized != combined.len)
        @panic("WireGuard allowed-IP allocation count does not match initialized routes");

    // The old subnet elements were moved into `combined`; only release their
    // container here so their owned address strings remain live.
    allocator.free(previous);
    peer.allowed_ips = combined;
}

fn cloneRouteDestination(
    allocator: std.mem.Allocator,
    route: *const api.Route,
    family: api.Address.Family,
) net.ConnectionCreateError!api.Subnet {
    if (route.destination) |*destination| return cloneSubnet(allocator, destination);
    return switch (family) {
        .v4 => (try api.Subnet.parseRawAlloc(allocator, "0.0.0.0/0")) orelse
            error.IncompleteModule,
        .v6 => (try api.Subnet.parseRawAlloc(allocator, "::/0")) orelse
            error.IncompleteModule,
        .hostname => error.IncompleteModule,
    };
}

fn cloneSubnet(
    allocator: std.mem.Allocator,
    subnet: *const api.Subnet,
) net.ConnectionCreateError!api.Subnet {
    return .{
        .address = (try api.Address.parseRawAlloc(allocator, subnet.address.raw)) orelse
            return error.IncompleteModule,
        .prefix_length = subnet.prefix_length,
    };
}

fn startV2(ptr: *anyopaque, remote: net.RemoteDescriptor) net.ConnectionStartError!bool {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    return self.startV2(remote);
}

fn commit(ptr: *anyopaque, descriptor: net.TunDescriptor) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.commit(descriptor);
}

const wireguard_connection_vtable = net.Connection.VTable{
    .start_v2 = startV2,
    .commit = commit,
    .stop = stop,
    .network_change = networkChange,
    .better_path = betterPath,
    .destroy = destroy,
};

fn stop(
    ptr: *anyopaque,
    timeout_ms: u32,
    events: net.Connection.Events,
) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.stop(timeout_ms, events);
}

fn networkChange(
    ptr: *anyopaque,
    reachability: net.ReachabilityInfo,
    events: net.Connection.Events,
) net.Connection.NetworkAction {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    return self.networkChange(reachability, events);
}

fn betterPath(ptr: *anyopaque, events: net.Connection.Events) net.Connection.NetworkAction {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    return self.betterPath(events);
}

fn destroy(ptr: *anyopaque) void {
    const self: *WireGuardConnection = @ptrCast(@alignCast(ptr));
    self.destroy();
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
    ) net.ConnectionCreateError!api.WireGuardConfiguration {
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

    pub fn simulateTemporaryShutdownRetrySchedulingFailure(
        connection: net.Connection,
        events: net.Connection.Events,
    ) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(connection.ptr));
        self.handleTemporaryShutdownRetrySchedulingFailure(
            events,
            error.ThreadQuotaExceeded,
        );
    }

    pub const effectiveMTU = TunnelRemoteInfoBuilder.effectiveMTU;
};

// MARK: - Error mapping

fn partoutCodeForError(err: ConnectionError) api.PartoutErrorCode {
    return switch (err) {
        error.InvalidEndpoint,
        => .linkNotActive,
        error.DNSResolutionFailure,
        => .dnsFailure,
        error.CannotLocateTunnelFileDescriptor,
        => .fdUnavailable,
        // error.CouldNotStartBackend,
        else => .unhandled,
    };
}
