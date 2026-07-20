// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../core/exports.zig");
const api = core.api;
const util = core.util;

pub const TunnelRemoteInfoBuilder = struct {
    allocator: std.mem.Allocator,
    profile: api.Profile,
    module_id: api.UUID,
    configuration: api.WireGuardConfiguration,

    pub const Error = std.mem.Allocator.Error || error{IdGeneration};

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        profile: api.Profile,
        module_id: api.UUID,
        configuration: api.WireGuardConfiguration,
    ) Self {
        return .{
            .allocator = allocator,
            .profile = profile,
            .module_id = module_id,
            .configuration = configuration,
        };
    }

    pub fn build(self: Self) Error!api.TunnelRemoteInfoWrapper {
        const modules = try self.buildModules();
        errdefer util.freeSlice(api.TaggedModule, self.allocator, modules);

        var profile = self.profile.clone(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson, error.InvalidModel, error.UnsupportedModel => unreachable,
        };
        errdefer profile.deinit(self.allocator);

        return .{
            .profile = profile,
            .original_module_id = self.module_id,
            // Apple requires one display endpoint even though WireGuard may
            // legitimately have zero endpoints or a different endpoint per
            // peer. Loopback is only a harmless settings placeholder; it is
            // never given to wg-go and cannot route onto the Internet.
            .address = api.Address.parseRaw("127.0.0.1").?,
            .requires_virtual_device = builtin.os.tag != .windows,
            .modules = modules,
        };
    }

    fn buildDNSModule(self: Self, source: api.DNSModule) Error!api.DNSModule {
        // Unlike the synthesized IP module below, this DNS module already
        // belongs to the WireGuard configuration. Preserve its identity just
        // as Swift does so controller/reporting code can correlate it.
        return source.clone(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson, error.InvalidModel, error.UnsupportedModel => unreachable,
        };
    }

    fn buildIPModule(self: Self) Error!api.IPModule {
        const id = try core.newId();
        var ipv4 = try self.buildIPSettings(.v4);
        errdefer ipv4.deinit(self.allocator);
        var ipv6 = try self.buildIPSettings(.v6);
        errdefer ipv6.deinit(self.allocator);

        return .{
            .id = id,
            .ipv4 = ipv4,
            .ipv6 = ipv6,
            .mtu = self.defaultMTU(),
        };
    }

    fn buildIPSettings(self: Self, family: api.Address.Family) Error!api.IPSettings {
        var subnets: std.ArrayList(api.Subnet) = .empty;
        defer util.deinitList(api.Subnet, self.allocator, &subnets);
        var routes: std.ArrayList(api.Route) = .empty;
        defer util.deinitList(api.Route, self.allocator, &routes);

        for (self.configuration.interface.addresses) |subnet| {
            if (subnet.address.family != family) continue;
            {
                var owned = try self.cloneInterfaceSubnet(subnet);
                errdefer owned.deinit(self.allocator);
                try subnets.append(self.allocator, owned);
            }
            {
                var owned = try self.buildInterfaceRoute(subnet);
                errdefer owned.deinit(self.allocator);
                try routes.append(self.allocator, owned);
            }
        }
        for (self.configuration.peers) |peer| {
            for (peer.allowed_ips) |subnet| {
                if (subnet.address.family != family) continue;
                var owned = try self.buildPeerRoute(subnet);
                errdefer owned.deinit(self.allocator);
                try routes.append(self.allocator, owned);
            }
        }

        const owned_subnets = try subnets.toOwnedSlice(self.allocator);
        errdefer util.freeSlice(api.Subnet, self.allocator, owned_subnets);
        const owned_routes = try routes.toOwnedSlice(self.allocator);
        return .{
            .subnets = owned_subnets,
            .included_routes = owned_routes,
            .excluded_routes = &.{},
        };
    }

    fn buildInterfaceRoute(self: Self, subnet: api.Subnet) Error!api.Route {
        const destination_text = subnet.networkRawAlloc(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidModel, error.Stringify => unreachable,
        };
        defer self.allocator.free(destination_text);

        var destination = (try api.Subnet.parseRawAlloc(self.allocator, destination_text)) orelse unreachable;
        errdefer destination.deinit(self.allocator);
        const gateway = (try api.Address.parseRawAlloc(self.allocator, subnet.address.raw)) orelse unreachable;
        return .{
            .destination = destination,
            .gateway = gateway,
        };
    }

    fn buildModules(self: Self) Error![]api.TaggedModule {
        var modules: std.ArrayList(api.TaggedModule) = .empty;
        defer util.deinitList(api.TaggedModule, self.allocator, &modules);

        {
            var module = api.TaggedModule{ .IP = try self.buildIPModule() };
            errdefer module.deinit(self.allocator);
            try modules.append(self.allocator, module);
        }
        if (self.configuration.interface.dns) |dns| {
            var module = api.TaggedModule{ .DNS = try self.buildDNSModule(dns) };
            errdefer module.deinit(self.allocator);
            try modules.append(self.allocator, module);
        }
        return modules.toOwnedSlice(self.allocator);
    }

    fn buildPeerRoute(self: Self, subnet: api.Subnet) Error!api.Route {
        return .{ .destination = try self.cloneSubnet(subnet, subnet.prefix_length) };
    }

    fn cloneInterfaceSubnet(self: Self, subnet: api.Subnet) Error!api.Subnet {
        // WireGuardKit carries this workaround for the broken iOS networking
        // stack: IPv6 interface prefixes narrower than /120 have no effect.
        // Widening /121.../128 to /120 is ugly and may expose more on-link
        // addresses than the configuration intended, but omitting it makes
        // common /128 WireGuard interface addresses unusable. Keep the route
        // below at the configured prefix; only the address assigned to the
        // virtual interface is clamped. Swift applies this before handing the
        // settings to any platform, so Zig deliberately preserves the clamp
        // everywhere even though the original workaround targets iOS.
        const prefix = if (subnet.address.family == .v6)
            @min(@as(u8, 120), subnet.prefix_length)
        else
            subnet.prefix_length;
        return self.cloneSubnet(subnet, prefix);
    }

    fn cloneSubnet(self: Self, subnet: api.Subnet, prefix: u8) Error!api.Subnet {
        return .{
            .address = (try api.Address.parseRawAlloc(self.allocator, subnet.address.raw)) orelse unreachable,
            .prefix_length = prefix,
        };
    }

    fn defaultMTU(self: Self) ?i32 {
        if (self.configuration.interface.mtu) |specified| {
            if (specified > 0) return @intCast(specified);
        }
        // Preserve WireGuardKit's platform defaults. iOS/tvOS deliberately use
        // the IPv6 minimum MTU; macOS leaves extra room below Ethernet's 1500
        // bytes for tunnel overhead. Other platforms use their native default.
        return switch (builtin.os.tag) {
            .ios, .tvos => 1280,
            .macos => 1400,
            else => 0,
        };
    }
};
