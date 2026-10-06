// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const api = core.api;
const log = core.logging;
const impl = @import("internal/backend.zig");
const PassiveIO = @import("internal/passive_io.zig").PassiveIO;
const PeerEndpointResolver = @import("internal/resolver.zig").PeerEndpointResolver;
const TunnelRemoteInfoBuilder = @import("internal/tunnel_info.zig").TunnelRemoteInfoBuilder;
const uapi = @import("internal/uapi.zig");

pub const ConnectionContext = struct {
    backend: impl.Backend,
    pub fn init(backend: impl.Backend) ConnectionContext {
        return .{ .backend = backend };
    }
};

pub fn createConnection(raw: ?*anyopaque, allocator: std.mem.Allocator, module: net.ConnectionModule, sandbox: net.Sandbox) net.ConnectionCreateError!net.Connection {
    const context: *const ConnectionContext = @ptrCast(@alignCast(raw orelse return error.MissingConnectionImplementation));
    const wg = switch (module.module.*) {
        .WireGuard => |*value| value,
        else => return error.MissingConnectionImplementation,
    };
    const configuration = if (wg.configuration) |*value| value else return error.IncompleteModule;
    const events = sandbox.events orelse return error.MissingConnectionImplementation;
    const complete = context.backend.vtable.complete_io orelse return error.MissingConnectionImplementation;
    var owned = try configurationApplyingActiveModules(allocator, configuration, sandbox.profile);
    errdefer owned.deinit(allocator);
    const builder = TunnelRemoteInfoBuilder.init(allocator, sandbox.profile, module.id(), &owned);
    const info = builder.build() catch |err| switch (err) {
        error.InvalidConfiguration => return error.IncompleteModule,
        else => |failure| return failure,
    };
    errdefer info.deinit(allocator);
    const self = try allocator.create(WireGuardConnection);
    self.* = .{
        .allocator = allocator,
        .configuration = owned,
        .info = info,
        .events = events,
        .backend = context.backend,
        .bridge = .{ .allocator = allocator, .complete = complete },
        .resolver = PeerEndpointResolver.init(owned.peers, sandbox.resolver, sandbox.factory, sandbox.options.dns_timeout),
        .interval_ms = sandbox.options.min_data_count_interval,
    };
    log.write(.notice, "Using WireGuardConnection v2");
    return .{ .ptr = self, .vtable = &vtable, .local_port = owned.interface.listen_port orelse 0 };
}

/// Lifecycle is confined to the daemon's looper. Only the blocking Go call
/// runs on Activation's worker. The daemon owns and replaces all native I/O.
const WireGuardConnection = struct {
    allocator: std.mem.Allocator,
    configuration: api.WireGuardConfiguration,
    info: api.TunnelRemoteInfoWrapper,
    events: net.Connection.Events,
    resolver: PeerEndpointResolver,
    backend: impl.Backend,
    bridge: PassiveIO,
    looper: ?*net.Looper = null,
    timer: net.Looper.Timer = .{},
    interval_ms: u32,
    handle: i32 = -1,
    activation: ?*Activation = null,
    state: State = .stopped,

    // A daemon reconnect detaches native I/O. A network refresh preserves Go;
    // all other failures, explicit stop and looper termination close it.
    const State = enum { stopped, activating, active, refresh_requested, suspended, stopping };
    const Operation = enum { start, refresh };

    fn start(self: *WireGuardConnection, remote: net.RemoteDescriptor) !void {
        std.debug.assert(self.state == .stopped and self.handle < 0);
        try self.activate(remote, .start);
    }

    fn refresh(self: *WireGuardConnection, remote: net.RemoteDescriptor) !void {
        std.debug.assert(self.state == .suspended and self.handle >= 0);
        try self.activate(remote, .refresh);
    }

    fn activate(self: *WireGuardConnection, remote: net.RemoteDescriptor, operation: Operation) !void {
        if (remote.local_port == 0 or remote.looper.implementation != .experimental) return error.UnableToStart;
        self.looper = remote.looper;
        self.state = .activating;
        errdefer self.prepareStop(.explicit_stop);
        self.resolver.reset(self.allocator);
        try self.resolver.cacheAll(self.allocator);
        const resolved = try self.resolver.resolve(self.allocator, std.EnumSet(net.DNSResolver.Flag).initEmpty());
        const settings = try switch (operation) {
            .start => uapi.buildConfiguration(self.allocator, &self.configuration, resolved),
            .refresh => uapi.buildEndpointConfiguration(self.allocator, &self.configuration, resolved),
        };
        errdefer self.allocator.free(settings);
        const pending = try self.allocator.create(Activation);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .owner = self, .operation = operation, .settings = settings, .port = remote.local_port };
        // Schedule before transferring ownership to the worker. On error no
        // worker can still reference the allocations released by errdefer.
        try self.scheduleActivation();
        self.bridge.activate(remote.looper);
        pending.thread = try std.Thread.spawn(.{}, Activation.run, .{pending});
        self.activation = pending;
    }

    const Activation = struct {
        owner: *WireGuardConnection,
        operation: Operation,
        settings: [:0]const u8,
        port: u16,
        thread: std.Thread = undefined,
        done: std.atomic.Value(bool) = .init(false),
        result: impl.Error!i32 = undefined,

        fn run(self: *Activation) void {
            self.result = self.callBackend();
            self.done.store(true, .release);
        }
        fn callBackend(self: *Activation) impl.Error!i32 {
            const owner = self.owner;
            switch (self.operation) {
                .start => return owner.backend.turnOn(owner.allocator, self.settings, owner.bridge.transport(self.port, passiveMTU(owner.info))),
                .refresh => {
                    if (try owner.backend.setConfig(owner.allocator, owner.handle, self.settings) != 0) return error.TransportFailure;
                    return owner.handle;
                },
            }
        }
    };

    fn joinActivation(self: *WireGuardConnection) !void {
        const pending = self.activation orelse return;
        pending.thread.join();
        defer {
            self.allocator.free(pending.settings);
            self.allocator.destroy(pending);
        }
        self.activation = null;
        const handle = try pending.result;
        if (handle < 0) return error.TransportFailure;
        self.handle = handle;
    }

    fn scheduleActivation(self: *WireGuardConnection) !void {
        try self.looper.?.scheduleReplacing(&self.timer, 1, .{ .context = self, .callback = onActivation });
    }
    fn onActivation(raw: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(raw.?));
        if (self.state != .activating) return;
        if (!self.activation.?.done.load(.acquire)) {
            self.scheduleActivation() catch self.fail(.unhandled);
            return;
        }
        self.joinActivation() catch {
            self.fail(.unhandled);
            return;
        };
        if (@import("builtin").os.tag == .ios) self.backend.disableRoaming(self.handle);
        self.state = .active;
        self.events.established(self.events.ctx, .{ .info = self.info });
        self.reportCount();
        self.scheduleCount() catch self.fail(.unhandled);
    }

    fn scheduleCount(self: *WireGuardConnection) !void {
        try self.looper.?.scheduleReplacing(&self.timer, @max(1, self.interval_ms), .{ .context = self, .callback = onCount });
    }
    fn onCount(raw: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(raw.?));
        if (self.state != .active) return;
        self.reportCount();
        self.scheduleCount() catch self.fail(.unhandled);
    }
    fn reportCount(self: *WireGuardConnection) void {
        const text = (self.backend.getConfig(self.allocator, self.handle) catch return) orelse return;
        defer self.allocator.free(text);
        if (uapi.parseRuntimeDataCount(text)) |count| self.events.data_count(self.events.ctx, count);
    }

    fn requestRefresh(self: *WireGuardConnection) void {
        // An unfinished activation cannot be retained for a new path.
        if (self.state == .activating) return self.fail(.networkChanged);
        if (self.state != .active) return;
        if (self.looper) |looper| looper.cancelTimer(&self.timer);
        self.state = .refresh_requested;
        self.events.failed(self.events.ctx, .{ .err_pair = .{ .code = .networkChanged }, .disposition = .reconnect });
    }
    fn fail(self: *WireGuardConnection, code: api.PartoutErrorCode) void {
        if (self.state != .active and self.state != .activating) return;
        self.prepareStop(.explicit_stop);
        self.events.failed(self.events.ctx, .{ .err_pair = .{ .code = code }, .disposition = .reconnect });
    }

    /// Called before native detachment. Pause a requested refresh, otherwise
    /// close admission and cancel reads. The daemon cancels writes on detach.
    fn prepareStop(self: *WireGuardConnection, reason: net.Connection.ShutdownReason) void {
        if (self.looper) |looper| looper.cancelTimer(&self.timer);
        const refreshing = self.state == .refresh_requested and switch (reason) {
            .failure => |disposition| disposition == .reconnect,
            .explicit_stop => false,
        };
        if (refreshing) {
            self.bridge.pause();
            self.state = .suspended;
        } else {
            self.bridge.quiesce();
            self.state = .stopping;
        }
    }

    /// Native I/O must already be detached and all writes completed/cancelled.
    /// This always closes Go, including activation in flight.
    fn stop(self: *WireGuardConnection) void {
        self.prepareStop(.explicit_stop);
        self.joinActivation() catch {};
        if (self.handle >= 0) self.backend.turnOff(self.handle);
        self.handle = -1;
        self.state = .stopped;
    }
    fn destroy(self: *WireGuardConnection) void {
        std.debug.assert(self.state == .stopped and self.activation == null and self.timer.id == null);
        self.bridge.lock.deinit();
        self.resolver.deinit(self.allocator);
        self.info.deinit(self.allocator);
        self.configuration.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn cast(ptr: *anyopaque) *WireGuardConnection {
    return @ptrCast(@alignCast(ptr));
}

// Adapt the daemon's transport lifecycle to WireGuard's backend lifecycle.
// start_v2 attaches a fresh session or resumes a suspended one; stop finalizes
// native detachment, retaining Go only for an explicitly requested refresh.
const vtable = net.Connection.VTable{
    .start_v2 = startV2,
    .read_buffers = readBuffers,
    .start = legacyStart,
    .shutdown = shutdown,
    .stop = transportDetached,
    .submit_packets = submitPackets,
    .looper_failed = looperFailed,
    .looper_terminated = looperTerminated,
    .network_change = networkChange,
    .better_path = betterPath,
    .destroy = destroy,
};
fn legacyStart(_: *anyopaque, _: net.Connection.Events) net.ConnectionStartError!bool {
    return error.UnableToStart;
}
fn startV2(ptr: *anyopaque, remote: net.RemoteDescriptor) net.ConnectionStartError!bool {
    const self = cast(ptr);
    switch (self.state) {
        .stopped => self.start(remote) catch |err| return startError(err),
        .suspended => self.refresh(remote) catch |err| return startError(err),
        else => return false,
    }
    return true;
}
fn shutdown(ptr: *anyopaque, reason: net.Connection.ShutdownReason) void {
    cast(ptr).prepareStop(reason);
}
fn transportDetached(ptr: *anyopaque, _: u32, _: net.Connection.Events) void {
    const self = cast(ptr);
    if (self.state != .suspended) self.stop();
}
fn destroy(ptr: *anyopaque) void {
    cast(ptr).destroy();
}
fn looperTerminated(ptr: *anyopaque, _: ?net.Looper.Failure) void {
    cast(ptr).stop();
}
fn looperFailed(ptr: *anyopaque, _: net.Side, _: net.Looper.Failure) void {
    cast(ptr).fail(.ioFailure);
}
fn networkChange(ptr: *anyopaque, info: net.ReachabilityInfo, _: net.Connection.Events) void {
    const self = cast(ptr);
    switch (self.state) {
        .active => self.requestRefresh(),
        // A reachable notification may have just started this activation.
        .activating => if (!info.reachable) self.fail(.networkChanged),
        else => {},
    }
}
fn betterPath(ptr: *anyopaque, _: net.Connection.Events) void {
    cast(ptr).requestRefresh();
}
fn readBuffers(ptr: *anyopaque, side: net.Side) ?net.Looper.ReadBuffers {
    return cast(ptr).bridge.readBuffers(side);
}
fn submitPackets(_: *anyopaque, _: net.Side, _: net.Looper.Packets, _: ?[]const net.SocketAddress) net.Looper.ReadAction {
    // Go receives data through the borrowed-buffer release callback.
    return .keep;
}
fn passiveMTU(info: api.TunnelRemoteInfoWrapper) u32 {
    for (info.modules orelse &.{}) |module| {
        if (module != .IP) continue;
        const mtu = module.IP.mtu orelse continue;
        if (mtu > 0) return @intCast(mtu);
    }
    // Only the passive Go device needs a concrete fallback. Host settings keep
    // the builder's zero/unspecified MTU and retain the native platform policy.
    return 1420;
}

fn startError(err: anyerror) net.ConnectionStartError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DNSResolutionFailure => error.DNSResolutionFailure,
        else => error.UnableToStart,
    };
}

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
    var extra: std.ArrayList(api.Subnet) = .empty;
    defer core.util.deinitList(api.Subnet, allocator, &extra);

    // Keep the Swift ordering: all active IP routes first (v4 then v6 per
    // module), followed by VPN-routed DNS server host routes.
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .IP => |*ip| {
                if (ip.ipv4) |*settings| for (settings.included_routes) |*route| {
                    try extra.ensureUnusedCapacity(allocator, 1);
                    extra.appendAssumeCapacity(try cloneRouteDestination(allocator, route, .v4));
                };
                if (ip.ipv6) |*settings| for (settings.included_routes) |*route| {
                    try extra.ensureUnusedCapacity(allocator, 1);
                    extra.appendAssumeCapacity(try cloneRouteDestination(allocator, route, .v6));
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
                    try extra.ensureUnusedCapacity(allocator, 1);
                    extra.appendAssumeCapacity((try api.Subnet.parseRawAlloc(allocator, server.raw)) orelse return error.IncompleteModule);
                }
            },
            else => {},
        }
    }
    if (extra.items.len == 0) return;
    const previous = peer.allowed_ips;
    const combined = try allocator.alloc(api.Subnet, previous.len + extra.items.len);
    @memcpy(combined[0..previous.len], previous);
    @memcpy(combined[previous.len..], extra.items);
    // Transfer the subnet strings; release only their old containers.
    allocator.free(previous);
    extra.clearRetainingCapacity();
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

// Expose the pure configuration transform for ownership and route parity tests.
pub const testing = struct {
    pub const configurationWithActiveModules = configurationApplyingActiveModules;
};
