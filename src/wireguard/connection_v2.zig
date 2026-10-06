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
    var owned = try configurationApplyingActiveModules(allocator, configuration, sandbox.profile);
    errdefer owned.deinit(allocator);
    const self = try allocator.create(WireGuardConnection);
    self.* = .{
        .allocator = allocator,
        .module_id = module.id(),
        .profile = sandbox.profile,
        .configuration = owned,
        .events = sandbox.events,
        .bridge = .{ .allocator = allocator, .backend = context.backend },
        .resolver = PeerEndpointResolver.init(owned.peers, sandbox.resolver, sandbox.factory, sandbox.options.dns_timeout),
        .interval_ms = sandbox.options.min_data_count_interval,
    };
    log.write(.notice, "Using WireGuardConnection v2");
    return .{ .ptr = self, .vtable = &vtable, .local_port = owned.interface.listen_port orelse 0 };
}

/// Protocol state is confined to the daemon's looper. This object never creates,
/// configures, attaches, detaches or closes a socket or native TUN.
const WireGuardConnection = struct {
    allocator: std.mem.Allocator,
    module_id: api.UUID,
    profile: *const api.Profile,
    configuration: api.WireGuardConfiguration,
    events: ?net.Connection.Events,
    resolver: PeerEndpointResolver,
    bridge: PassiveIO,
    timer: net.Looper.Timer = .{},
    interval_ms: u32,
    failed: bool = false,
    pending_info: ?api.TunnelRemoteInfoWrapper = null,

    fn startV2(self: *WireGuardConnection, remote: net.RemoteDescriptor) !bool {
        if (self.bridge.handle >= 0 or self.bridge.startup != null) return false;
        if (self.events == null) return error.UnableToStart;
        self.failed = false;
        self.resolver.reset(self.allocator);
        try self.resolver.cacheAll(self.allocator);
        const resolved = try self.resolver.resolve(self.allocator, std.EnumSet(net.DNSResolver.Flag).initEmpty());
        const settings = try uapi.buildConfiguration(self.allocator, &self.configuration, resolved);
        defer self.allocator.free(settings);
        const builder = TunnelRemoteInfoBuilder.init(self.allocator, self.profile, self.module_id, &self.configuration);
        var info = try builder.build();
        errdefer info.deinit(self.allocator);
        try self.bridge.start(remote, passiveMTU(info), settings);
        errdefer self.quiesce();
        try self.scheduleCount();
        self.pending_info = info;
        return true;
    }

    fn scheduleCount(self: *WireGuardConnection) !void {
        const looper = self.bridge.looper.?;
        try looper.scheduleReplacing(&self.timer, if (self.bridge.startup != null) 1 else @max(1, self.interval_ms), .{ .context = self, .callback = onCount });
    }
    fn onCount(raw: ?*anyopaque) void {
        const self: *WireGuardConnection = @ptrCast(@alignCast(raw.?));
        if (self.failed) return;
        if (self.pending_info) |info| {
            const started = self.bridge.pollStart() catch {
                self.fail(.unhandled);
                return;
            };
            if (!started) {
                self.scheduleCount() catch self.fail(.unhandled);
                return;
            }
            if (@import("builtin").os.tag == .ios) self.bridge.backend.disableRoaming(self.bridge.handle);
            self.pending_info = null;
            defer info.deinit(self.allocator);
            if (self.events) |events| events.established(events.ctx, .{ .info = info });
        }
        if (self.bridge.handle < 0) return;
        self.reportCount();
        self.scheduleCount() catch self.fail(.unhandled);
    }
    fn reportCount(self: *WireGuardConnection) void {
        const events = self.events orelse return;
        const text = (self.bridge.backend.getConfig(self.allocator, self.bridge.handle) catch return) orelse return;
        defer self.allocator.free(text);
        if (uapi.parseRuntimeDataCount(text)) |count| events.data_count(events.ctx, count);
    }
    fn quiesce(self: *WireGuardConnection) void {
        if (self.bridge.looper) |looper| looper.cancelTimer(&self.timer);
        self.bridge.quiesce();
    }
    fn stop(self: *WireGuardConnection) void {
        self.quiesce();
        self.bridge.stop();
        if (self.pending_info) |*info| info.deinit(self.allocator);
        self.pending_info = null;
    }
    fn fail(self: *WireGuardConnection, code: api.PartoutErrorCode) void {
        if (self.failed or (self.bridge.handle < 0 and self.pending_info == null)) return;
        self.failed = true;
        if (self.events) |events| events.failed(events.ctx, .{ .err_pair = .{ .code = code }, .disposition = .reconnect });
    }
    fn destroy(self: *WireGuardConnection) void {
        // The owner quiesces us on the looper before destroying on its actor.
        std.debug.assert(self.bridge.handle < 0 and self.bridge.startup == null and self.pending_info == null and self.timer.id == null);
        self.bridge.lock.deinit();
        self.resolver.deinit(self.allocator);
        self.configuration.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn cast(ptr: *anyopaque) *WireGuardConnection {
    return @ptrCast(@alignCast(ptr));
}
const vtable = net.Connection.VTable{
    .start_v2 = startV2,
    .read_buffers = readBuffers,
    .start = legacyStart,
    .shutdown = shutdown,
    .stop = stop,
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
    return cast(ptr).startV2(remote) catch |err| return startError(err);
}
fn shutdown(ptr: *anyopaque, _: net.Connection.ShutdownReason) void {
    cast(ptr).quiesce();
}
fn stop(ptr: *anyopaque, _: u32, _: net.Connection.Events) void {
    cast(ptr).stop();
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
    // The daemon may just have started activation in response to this same
    // reachable notification. That fresh socket already uses the new path.
    if (info.reachable and self.bridge.handle < 0) return;
    // Reachability callbacks also announce usable-to-usable path changes.
    // Rebuild the host socket and resolve endpoints again (including DNS64)
    // even when availability stays true. Better-path events are only a subset.
    self.fail(.networkChanged);
}
fn betterPath(ptr: *anyopaque, _: net.Connection.Events) void {
    cast(ptr).fail(.networkChanged);
}
fn readBuffers(ptr: *anyopaque, side: net.Side) ?net.Looper.ReadBuffers {
    return cast(ptr).bridge.readBuffers(side);
}
fn submitPackets(_: *anyopaque, _: net.Side, _: net.Looper.Packets, _: ?[]const net.SocketAddress) net.Looper.ReadAction {
    // The read-buffer provider completes Go requests after this callback.
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
