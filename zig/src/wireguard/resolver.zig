// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");

const api = core.api;
const log = core.logging;
const util = core.util;

pub const ResolutionError = std.mem.Allocator.Error || error{
    DNSResolutionFailure,
    InvalidEndpoint,
};

/// Maps a configured endpoint to the owned numeric endpoint sent to wg-go.
pub const ResolvedEndpoint = struct {
    source: api.Endpoint,
    base: api.Endpoint,
    target: api.Endpoint,

    pub fn deinit(self: *const ResolvedEndpoint, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        self.target.deinit(allocator);
    }
};

pub const PeerEndpointResolver = struct {
    peers: []const api.WireGuardRemoteInterface,
    resolver: net.DNSResolver,
    factory: ?net.SocketFactory,
    timeout_ms: u32,
    cache: Cache = .{},

    /// `null` means unresolved; a non-null empty slice is a valid result.
    const Cache = struct {
        entries: ?[]ResolvedEndpoint = null,

        fn value(self: *const Cache) ?[]const ResolvedEndpoint {
            return self.entries;
        }

        fn mutableValue(self: *const Cache) ?[]ResolvedEndpoint {
            return self.entries;
        }

        fn setValue(self: *Cache, entries: []ResolvedEndpoint) void {
            std.debug.assert(self.entries == null);
            self.entries = entries;
        }

        fn reset(self: *Cache, allocator: std.mem.Allocator) void {
            if (self.entries) |entries| util.freeSlice(ResolvedEndpoint, allocator, entries);
            self.entries = null;
        }

        fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
            self.reset(allocator);
        }
    };

    /// Owns entries while the resolution map is being assembled.
    const List = struct {
        allocator: std.mem.Allocator,
        entries: std.ArrayList(ResolvedEndpoint) = .empty,

        fn init(allocator: std.mem.Allocator) List {
            return .{ .allocator = allocator };
        }

        fn append(self: *List, entry: ResolvedEndpoint) error{OutOfMemory}!void {
            self.entries.append(self.allocator, entry) catch |err| {
                var owned = entry;
                owned.deinit(self.allocator);
                return err;
            };
        }

        fn deinit(self: *List) void {
            util.deinitList(ResolvedEndpoint, self.allocator, &self.entries);
        }

        fn toOwnedSlice(self: *List) error{OutOfMemory}![]ResolvedEndpoint {
            return self.entries.toOwnedSlice(self.allocator);
        }
    };

    pub fn init(
        peers: []const api.WireGuardRemoteInterface,
        resolver: net.DNSResolver,
        factory: ?net.SocketFactory,
        timeout_ms: u32,
    ) PeerEndpointResolver {
        return .{
            .peers = peers,
            .resolver = resolver,
            .factory = factory,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *PeerEndpointResolver, allocator: std.mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    pub fn reset(self: *PeerEndpointResolver, allocator: std.mem.Allocator) void {
        self.cache.reset(allocator);
    }

    pub fn cacheAll(self: *PeerEndpointResolver, allocator: std.mem.Allocator) ResolutionError!void {
        if (self.cache.value() != null) return;

        // First half of WireGuardKit's DNS64 workaround: request every address
        // so a real A record remains available even if the active DNS64 network
        // would otherwise expose only a synthesized AAAA record. The chosen
        // numeric base is retained until an offline interval forces a reset.
        var flags = std.EnumSet(net.DNSResolver.Flag).initEmpty();
        flags.insert(.allAddresses);
        try self.populate(allocator, flags);
    }

    pub fn resolve(
        self: *PeerEndpointResolver,
        allocator: std.mem.Allocator,
        flags: std.EnumSet(net.DNSResolver.Flag),
    ) ResolutionError![]const ResolvedEndpoint {
        if (self.cache.value() == null) try self.populate(allocator, flags);

        // Second half of the workaround: reinterpret each cached numeric base
        // for the current network immediately before emitting UAPI. On Apple
        // DNS64 networks this can replace an obsolete NAT64 prefix without a
        // new hostname lookup; other resolvers simply preserve the address.
        try self.refreshTargets(allocator);
        return self.cache.value().?;
    }

    fn populate(
        self: *PeerEndpointResolver,
        allocator: std.mem.Allocator,
        flags: std.EnumSet(net.DNSResolver.Flag),
    ) ResolutionError!void {
        std.debug.assert(self.cache.value() == null);

        var entries = List.init(allocator);
        errdefer entries.deinit();
        const reachability = if (self.factory) |factory| factory.currentReachability() else null;
        var failures: usize = 0;

        // ZIGME: Swift resolves peer hostnames concurrently with a task group.
        // This simpler loop makes DNS timeouts additive when several peers are
        // unreachable; use bounded concurrent resolution if that becomes a
        // measurable startup problem.
        for (self.peers) |peer| {
            const endpoint = peer.endpoint orelse continue;
            var base = self.resolveEndpoint(
                allocator,
                endpoint,
                flags,
                reachability,
            ) catch |err| {
                log.writef(.err, "WireGuard: Failed to resolve endpoint {s}: {}", .{
                    endpoint.address,
                    err,
                });
                if (err == error.OutOfMemory) return error.OutOfMemory;
                failures += 1;
                continue;
            };
            const target = base.clone(allocator) catch |err| {
                base.deinit(allocator);
                return err;
            };
            try entries.append(.{
                .source = endpoint,
                .base = base,
                .target = target,
            });
        }
        if (failures > 0) return error.DNSResolutionFailure;

        self.cache.setValue(try entries.toOwnedSlice());
    }

    fn refreshTargets(
        self: *const PeerEndpointResolver,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!void {
        const reachability = if (self.factory) |factory| factory.currentReachability() else null;
        const entries = self.cache.mutableValue().?;
        for (entries) |*entry| {
            var mapped = self.resolver.resolveAddress(
                allocator,
                entry.base.address,
                reachability,
                self.timeout_ms,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NetworkUnreachable, error.ResolutionFailure, error.Timeout => fallback: {
                    log.writef(.err, "WireGuard: Unable to remap endpoint {s}: {}", .{
                        entry.base.address,
                        err,
                    });
                    break :fallback try allocator.dupe(u8, entry.base.address);
                },
            };

            const parsed = api.Address.parseRaw(mapped);
            if (parsed == null or !parsed.?.isIPAddress()) {
                log.writef(.err, "WireGuard: Resolver returned invalid mapped address for {s}", .{entry.base.address});
                allocator.free(mapped);
                mapped = try allocator.dupe(u8, entry.base.address);
            }

            var previous = entry.target;
            entry.target = .{
                .address = mapped,
                .port = entry.base.port,
                .owned = true,
            };
            previous.deinit(allocator);
            logMapping(entry.base.address, entry.target.address);
        }
    }

    fn resolveEndpoint(
        self: *const PeerEndpointResolver,
        allocator: std.mem.Allocator,
        endpoint: api.Endpoint,
        flags: std.EnumSet(net.DNSResolver.Flag),
        reachability: ?net.ReachabilityInfo,
    ) ResolutionError!api.Endpoint {
        const address = api.Address.parseRaw(endpoint.address) orelse return error.InvalidEndpoint;
        if (address.isIPAddress()) {
            // Numeric endpoints bypass hostname resolution, but still pass
            // through `resolveAddress` when UAPI is built so DNS64 synthesis
            // can adapt an IPv4 literal to the active network.
            logMapping(endpoint.address, endpoint.address);
            return endpoint.clone(allocator);
        }

        const records = self.resolver.resolve(
            allocator,
            endpoint.address,
            flags,
            reachability,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NetworkUnreachable, error.ResolutionFailure, error.Timeout => return error.DNSResolutionFailure,
        };
        defer util.freeSlice(net.DNSRecord, allocator, records);

        const target_address = preferredAddress(records) orelse return error.DNSResolutionFailure;
        logMapping(endpoint.address, target_address);
        return (api.Endpoint{
            .address = target_address,
            .port = endpoint.port,
        }).clone(allocator);
    }
};

fn preferredAddress(records: []const net.DNSRecord) ?[]const u8 {
    // Match WireGuardKit: prefer the first IPv4 record even when DNS64 put a
    // synthesized IPv6 record first, otherwise use the first numeric result.
    var first: ?[]const u8 = null;
    for (records) |record| {
        const address = api.Address.parseRaw(record.address) orelse continue;
        if (!address.isIPAddress()) continue;
        if (first == null) first = address.raw;
        if (address.family == .v4) return address.raw;
    }
    return first;
}

fn logMapping(source: []const u8, target: []const u8) void {
    if (std.mem.eql(u8, source, target)) {
        log.writef(.debug, "WireGuard: DNS64 mapped {s} to itself", .{source});
    } else {
        log.writef(.debug, "WireGuard: DNS64 mapped {s} to {s}", .{ source, target });
    }
}
