// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const configuration_mod = @import("configuration.zig");

const api = core_mod.api;

/// Merges local and pushed OpenVPN settings into owned core modules.
pub const NetworkSettingsBuilder = struct {
    local_options: *const api.OpenVPNConfiguration,
    remote_options: *const api.OpenVPNConfiguration,

    pub fn init(
        local_options: *const api.OpenVPNConfiguration,
        remote_options: *const api.OpenVPNConfiguration,
    ) NetworkSettingsBuilder {
        return .{
            .local_options = local_options,
            .remote_options = remote_options,
        };
    }

    pub fn modules(
        self: NetworkSettingsBuilder,
        allocator: std.mem.Allocator,
    ) ![]api.TaggedModule {
        var result: std.ArrayList(api.TaggedModule) = .empty;
        errdefer {
            for (result.items) |*module| module.deinit(allocator);
            result.deinit(allocator);
        }

        if (try self.ipModule(allocator)) |module| try result.append(allocator, .{ .IP = module });
        const dns = self.dnsModule(allocator) catch |err| switch (err) {
            error.OutOfMemory, error.IdGeneration => return err,
            else => null,
        };
        if (dns) |module| try result.append(allocator, .{ .DNS = module });
        const http_proxy = self.httpProxyModule(allocator) catch |err| switch (err) {
            error.OutOfMemory, error.IdGeneration => return err,
            else => null,
        };
        if (http_proxy) |module| try result.append(allocator, .{ .HTTPProxy = module });
        return result.toOwnedSlice(allocator);
    }

    pub fn deinitModules(allocator: std.mem.Allocator, modules_value: []api.TaggedModule) void {
        for (modules_value) |*module| module.deinit(allocator);
        allocator.free(modules_value);
    }

    fn pulls(self: NetworkSettingsBuilder, mask: api.OpenVPNPullMask) bool {
        return !configuration_mod.hasPullMask(self.local_options, mask);
    }

    fn routingPolicies(self: NetworkSettingsBuilder) ?[]const api.OpenVPNRoutingPolicy {
        if (!self.pulls(.routes)) return self.local_options.routing_policies;
        return self.remote_options.routing_policies orelse self.local_options.routing_policies;
    }

    fn isGateway(self: NetworkSettingsBuilder, family: api.OpenVPNRoutingPolicy) bool {
        const policies = self.routingPolicies() orelse return false;
        return std.mem.indexOfScalar(api.OpenVPNRoutingPolicy, policies, family) != null;
    }

    fn ipModule(
        self: NetworkSettingsBuilder,
        allocator: std.mem.Allocator,
    ) !?api.IPModule {
        var ipv4 = if (self.remote_options.ipv4) |settings|
            try self.ipSettings(
                allocator,
                settings,
                self.local_options.routes4,
                self.remote_options.routes4,
                self.remote_options.route_gateway4,
                self.isGateway(.IPv4),
            )
        else
            null;
        errdefer if (ipv4) |*settings| settings.deinit(allocator);

        var ipv6 = if (self.remote_options.ipv6) |settings|
            try self.ipSettings(
                allocator,
                settings,
                self.local_options.routes6,
                self.remote_options.routes6,
                self.remote_options.route_gateway6,
                self.isGateway(.IPv6),
            )
        else
            null;
        errdefer if (ipv6) |*settings| settings.deinit(allocator);

        const mtu = if (self.local_options.mtu) |value|
            if (value > 0) value else null
        else
            null;
        if (ipv4 == null and ipv6 == null and mtu == null) return null;

        return .{
            .id = try core_mod.newId(),
            .ipv4 = ipv4,
            .ipv6 = ipv6,
            .mtu = mtu,
        };
    }

    fn ipSettings(
        self: NetworkSettingsBuilder,
        allocator: std.mem.Allocator,
        server: api.IPSettings,
        local_routes: ?[]const api.Route,
        remote_routes: ?[]const api.Route,
        default_gateway: ?api.Address,
        add_default: bool,
    ) !api.IPSettings {
        var collected: std.ArrayList(api.Route) = .empty;
        defer collected.deinit(allocator);
        try collected.appendSlice(allocator, server.included_routes);
        if (local_routes) |routes| try collected.appendSlice(allocator, routes);
        if (self.pulls(.routes)) {
            if (remote_routes) |routes| try collected.appendSlice(allocator, routes);
        }
        if (add_default) try collected.append(allocator, .{ .gateway = default_gateway });

        var effective: std.ArrayList(api.Route) = .empty;
        defer effective.deinit(allocator);
        for (collected.items) |route| {
            try effective.append(allocator, .{
                .destination = route.destination,
                .gateway = route.gateway orelse default_gateway,
            });
        }
        return (api.IPSettings{
            .subnets = server.subnets,
            .included_routes = effective.items,
            .excluded_routes = server.excluded_routes,
        }).clone(allocator);
    }

    fn dnsModule(
        self: NetworkSettingsBuilder,
        allocator: std.mem.Allocator,
    ) !?api.DNSModule {
        var raw_servers: std.ArrayList([]const u8) = .empty;
        defer raw_servers.deinit(allocator);
        if (self.local_options.dns_servers) |servers| try raw_servers.appendSlice(allocator, servers);
        if (self.pulls(.dns)) {
            if (self.remote_options.dns_servers) |servers| try raw_servers.appendSlice(allocator, servers);
        }
        if (raw_servers.items.len == 0) return null;

        const servers = try addressesAlloc(allocator, raw_servers.items);
        errdefer freeAddresses(allocator, servers);

        const raw_domain = if (self.pulls(.dns))
            self.remote_options.dns_domain orelse self.local_options.dns_domain
        else
            self.local_options.dns_domain;
        var domain_name: ?api.Address = if (raw_domain) |domain|
            (try api.Address.parseRawAlloc(allocator, domain)) orelse return error.InvalidAddress
        else
            null;
        errdefer if (domain_name) |*domain| domain.deinit(allocator);

        var raw_search: std.ArrayList([]const u8) = .empty;
        defer raw_search.deinit(allocator);
        if (self.local_options.search_domains) |domains| try raw_search.appendSlice(allocator, domains);
        if (self.pulls(.dns)) {
            if (self.remote_options.search_domains) |domains| try raw_search.appendSlice(allocator, domains);
        }
        if (raw_domain) |domain| removeString(&raw_search, domain);

        const search_domains: ?[]api.Address = if (raw_search.items.len > 0)
            try addressesAlloc(allocator, raw_search.items)
        else
            null;
        errdefer if (search_domains) |domains| freeAddresses(allocator, domains);

        return .{
            .id = try core_mod.newId(),
            .servers = servers,
            .domain_name = domain_name,
            .search_domains = search_domains,
            .domain_policy = null,
        };
    }

    fn httpProxyModule(
        self: NetworkSettingsBuilder,
        allocator: std.mem.Allocator,
    ) !?api.HTTPProxyModule {
        const proxy_source = if (self.pulls(.proxy))
            self.remote_options.http_proxy orelse self.local_options.http_proxy
        else
            self.local_options.http_proxy;
        const secure_source = if (self.pulls(.proxy))
            self.remote_options.https_proxy orelse self.local_options.https_proxy
        else
            self.local_options.https_proxy;
        const pac_source = if (self.pulls(.proxy))
            self.remote_options.proxy_auto_configuration_url orelse self.local_options.proxy_auto_configuration_url
        else
            self.local_options.proxy_auto_configuration_url;
        if (proxy_source == null and secure_source == null and pac_source == null) return null;

        var proxy = if (proxy_source) |value| try value.clone(allocator) else null;
        errdefer if (proxy) |*value| value.deinit(allocator);
        var secure_proxy = if (secure_source) |value| try value.clone(allocator) else null;
        errdefer if (secure_proxy) |*value| value.deinit(allocator);
        const pac_url = if (pac_source) |value| try allocator.dupe(u8, value) else null;
        errdefer if (pac_url) |value| allocator.free(value);

        var raw_bypass: std.ArrayList([]const u8) = .empty;
        defer raw_bypass.deinit(allocator);
        if (self.local_options.proxy_bypass_domains) |domains| try raw_bypass.appendSlice(allocator, domains);
        if (self.pulls(.proxy)) {
            if (self.remote_options.proxy_bypass_domains) |domains| try raw_bypass.appendSlice(allocator, domains);
        }
        const bypass = try addressesAlloc(allocator, raw_bypass.items);
        errdefer freeAddresses(allocator, bypass);

        return .{
            .id = try core_mod.newId(),
            .proxy = proxy,
            .secure_proxy = secure_proxy,
            .pac_url = pac_url,
            .bypass_domains = bypass,
        };
    }
};

fn addressesAlloc(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]api.Address {
    const addresses = try allocator.alloc(api.Address, values.len);
    var initialized: usize = 0;
    errdefer {
        for (addresses[0..initialized]) |*address| address.deinit(allocator);
        allocator.free(addresses);
    }
    for (values, 0..) |value, index| {
        addresses[index] = (try api.Address.parseRawAlloc(allocator, value)) orelse return error.InvalidAddress;
        initialized += 1;
    }
    return addresses;
}

fn freeAddresses(allocator: std.mem.Allocator, addresses: []api.Address) void {
    for (addresses) |*address| address.deinit(allocator);
    allocator.free(addresses);
}

fn removeString(list: *std.ArrayList([]const u8), value: []const u8) void {
    var index: usize = 0;
    while (index < list.items.len) {
        if (std.mem.eql(u8, list.items[index], value)) {
            _ = list.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}
