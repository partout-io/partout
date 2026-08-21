// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");

const api = core.api;
const log = core.logging;

pub const EndpointResolver = struct {
    endpoints: []const api.ExtendedEndpoint,
    next_endpoint_index: usize,
    resolved: ?[]api.ExtendedEndpoint,
    next_resolved_index: usize,

    // MARK: - Public API

    pub fn init(endpoints: []const api.ExtendedEndpoint) EndpointResolver {
        std.debug.assert(endpoints.len > 0);
        return .{
            .endpoints = endpoints,
            .next_endpoint_index = 0,
            .resolved = null,
            .next_resolved_index = 0,
        };
    }

    pub fn deinit(self: *EndpointResolver, allocator: std.mem.Allocator) void {
        self.clearResolved(allocator);
    }

    pub fn next(
        self: *EndpointResolver,
        allocator: std.mem.Allocator,
        resolver: *const net.DNSResolver,
        reachability: ?net.ReachabilityInfo,
        timeout_ms: u32,
    ) (std.mem.Allocator.Error || error{ExhaustedEndpoints})!api.ExtendedEndpoint {
        while (true) {
            if (self.resolved) |resolved| {
                if (self.next_resolved_index < resolved.len) {
                    const endpoint = resolved[self.next_resolved_index];
                    self.next_resolved_index += 1;
                    return endpoint;
                }
                self.clearResolved(allocator);
            }

            if (self.next_endpoint_index >= self.endpoints.len) {
                self.next_endpoint_index = 0;
                return error.ExhaustedEndpoints;
            }
            const source = self.endpoints[self.next_endpoint_index];
            self.next_endpoint_index += 1;
            self.resolved = resolveEndpoint(
                allocator,
                resolver,
                source,
                reachability,
                timeout_ms,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NetworkUnreachable,
                error.ResolutionFailure,
                error.Timeout,
                => {
                    log.writef(.err, "Unable to resolve {s}: {s}", .{
                        log.sensitive(source.address),
                        @errorName(err),
                    });
                    continue;
                },
            };
            self.next_resolved_index = 0;
        }
    }

    // MARK: - Private helpers

    fn clearResolved(
        self: *EndpointResolver,
        allocator: std.mem.Allocator,
    ) void {
        if (self.resolved) |resolved|
            core.util.freeSlice(api.ExtendedEndpoint, allocator, resolved);
        self.resolved = null;
        self.next_resolved_index = 0;
    }
};

fn resolveEndpoint(
    allocator: std.mem.Allocator,
    resolver: *const net.DNSResolver,
    endpoint: api.ExtendedEndpoint,
    reachability: ?net.ReachabilityInfo,
    timeout_ms: u32,
) net.DNSResolver.Error![]api.ExtendedEndpoint {
    const address = api.Address.parseRaw(endpoint.address) orelse
        return error.ResolutionFailure;
    if (address.isIPAddress()) {
        const mapped = try resolver.resolveAddress(
            allocator,
            endpoint.address,
            reachability,
            timeout_ms,
        );
        defer allocator.free(mapped);
        const mapped_address = api.Address.parseRaw(mapped) orelse
            return error.ResolutionFailure;
        if (!mapped_address.isIPAddress() or
            !isCompatibleAddress(endpoint, mapped_address.family == .v6))
        {
            return error.ResolutionFailure;
        }
        const result = try allocator.alloc(api.ExtendedEndpoint, 1);
        errdefer allocator.free(result);
        result[0] = try ownedEndpoint(allocator, endpoint, mapped);
        return result;
    }

    const records = try resolver.resolve(
        allocator,
        endpoint.address,
        std.EnumSet(net.DNSResolver.Flag).initEmpty(),
        reachability,
        timeout_ms,
    );
    defer core.util.freeSlice(net.DNSRecord, allocator, records);
    var result: std.ArrayList(api.ExtendedEndpoint) = .empty;
    errdefer core.util.deinitList(api.ExtendedEndpoint, allocator, &result);
    for (records) |record| {
        const resolved_address = api.Address.parseRaw(record.address) orelse continue;
        if (!resolved_address.isIPAddress()) continue;
        if (!isCompatibleAddress(endpoint, record.is_ipv6)) continue;
        try result.ensureUnusedCapacity(allocator, 1);
        result.appendAssumeCapacity(try ownedEndpoint(allocator, endpoint, record.address));
    }
    return result.toOwnedSlice(allocator);
}

fn ownedEndpoint(
    allocator: std.mem.Allocator,
    source: api.ExtendedEndpoint,
    address: []const u8,
) std.mem.Allocator.Error!api.ExtendedEndpoint {
    return .{
        .address = try allocator.dupe(u8, address),
        .proto = source.proto,
        .owned = true,
    };
}

fn isCompatibleAddress(endpoint: api.ExtendedEndpoint, is_ipv6: bool) bool {
    return switch (endpoint.proto.socket_type) {
        .udp4, .tcp4 => !is_ipv6,
        .udp6, .tcp6 => is_ipv6,
        .udp, .tcp => true,
    };
}
