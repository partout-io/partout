// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const io = @import("io.zig");
const sandbox = @import("sandbox.zig");
const c = c_mod.io;
const log = core.logging;

const DNSRecord = sandbox.DNSRecord;
const DNSResolver = sandbox.DNSResolver;
const ReachabilityInfo = io.ReachabilityInfo;
const ResolveFn = *const fn ([:0]const u8, bool, ?*const ReachabilityInfo, *c.pp_dns_result) c_int;

// Timed-out slots remain occupied until their uncancellable query returns.
const max_pending_queries = 3;

pub const PlatformDNS = struct {
    pub fn init() PlatformDNS {
        return .{};
    }

    pub fn interface(self: *PlatformDNS) DNSResolver {
        return .{
            .ptr = self,
            .resolve_block = resolveBlock,
            .resolve_address_block = resolveAddressBlock,
        };
    }

    /// Reinterprets a numeric address through the platform resolver.
    ///
    /// On iOS/tvOS this is the second half of WireGuardKit's DNS64 workaround:
    /// resolving a cached IPv4 literal lets `getaddrinfo` synthesize an IPv6
    /// address using the NAT64 prefix of the network that is active now. Other
    /// platforms do not need this extra pass and preserve the address verbatim.
    pub fn resolveAddress(
        self: *const PlatformDNS,
        allocator: std.mem.Allocator,
        address: []const u8,
        reachability: ?ReachabilityInfo,
        timeout_ms: u32,
    ) DNSResolver.Error![]u8 {
        if (comptime builtin.os.tag != .ios and builtin.os.tag != .tvos) {
            return allocator.dupe(u8, address);
        }

        const records = try self.resolve(
            allocator,
            address,
            .initEmpty(),
            reachability,
            timeout_ms,
        );
        defer core.util.freeSlice(DNSRecord, allocator, records);
        for (records) |record| {
            const parsed = core.api.Address.parseRaw(record.address) orelse continue;
            if (parsed.isIPAddress()) return allocator.dupe(u8, parsed.raw);
        }
        return error.ResolutionFailure;
    }

    pub fn resolve(
        self: *const PlatformDNS,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(DNSResolver.Flag),
        reachability: ?ReachabilityInfo,
        timeout_ms: u32,
    ) DNSResolver.Error![]DNSRecord {
        return self.resolveWith(allocator, hostname, flags, reachability, timeout_ms, resolveNative);
    }

    fn resolveWith(
        _: *const PlatformDNS,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(DNSResolver.Flag),
        reachability: ?ReachabilityInfo,
        timeout_ms: u32,
        resolve_fn: ResolveFn,
    ) DNSResolver.Error![]DNSRecord {
        if (builtin.abi.isAndroid()) {
            const info = reachability orelse return error.NetworkUnreachable;
            if (info.network_handle == 0) return error.NetworkUnreachable;
            log.writef(.info, "resolveAndBlock() with Android network handle: {}", .{info.network_handle});
        }

        const query = query_pool.acquire(
            hostname,
            flags.contains(.allAddresses) and builtin.os.tag.isDarwin(),
            reachability,
            resolve_fn,
        ) catch |err| return err;

        var timer: core.RunAfter = .{};
        timer.scheduleReplacing(timeout_ms, Query.timeout, query) catch |err| {
            timer.deinit();
            query_pool.releaseUnstarted(query);
            log.writef(.err, "Unable to start DNS timeout: {s}", .{@errorName(err)});
            return if (err == error.OutOfMemory) error.OutOfMemory else error.ResolutionFailure;
        };

        const thread = std.Thread.spawn(.{}, Query.run, .{query}) catch |err| {
            timer.cancel();
            timer.deinit();
            query_pool.releaseUnstarted(query);
            log.writef(.err, "Unable to start DNS resolution: {s}", .{@errorName(err)});
            return if (err == error.OutOfMemory) error.OutOfMemory else error.ResolutionFailure;
        };

        query_pool.mutex.lock();
        while (!query.worker_done and !query.timed_out) query_pool.cond.wait(&query_pool.mutex);
        const timed_out = query.timed_out;
        const status = query.status;
        var result: c.pp_dns_result = null;
        if (!timed_out) {
            result = query.result;
            query.result = null;
        }
        query_pool.mutex.unlock();

        timer.cancel();
        timer.deinit();
        query_pool.mutex.lock();
        query.caller_done = true;
        query.recycleLocked();
        query_pool.mutex.unlock();
        if (timed_out) {
            thread.detach();
            log.writef(.err, "DNS resolution timed out for {s}", .{
                log.sensitive(hostname),
            });
            return error.Timeout;
        }
        thread.join();

        defer if (result) |info| c.pp_dns_free(info);
        if (status != 0) {
            if (c.pp_dns_error_is_bad_flags(status)) {
                log.write(.fault, "getaddrinfo() failed with EAI_BADFLAGS");
            } else {
                log.writef(.fault, "getaddrinfo() failed with result {}", .{status});
            }
            return error.ResolutionFailure;
        }

        // Iterate through DNS results
        var records: std.ArrayList(DNSRecord) = .empty;
        errdefer {
            for (records.items) |record| record.deinit(allocator);
            records.deinit(allocator);
        }
        var item = result;
        while (item) |info| : (item = c.pp_dns_next(info)) {
            var address_buffer: [c.PPDNSAddressStringMax]u8 =
                [_]u8{0} ** c.PPDNSAddressStringMax;
            var is_ipv6 = false;
            if (!c.pp_dns_address_string(
                info,
                &address_buffer,
                address_buffer.len,
                &is_ipv6,
            )) {
                log.writef(.err, "getnameinfo() failed for {s}", .{
                    log.sensitive(hostname),
                });
                continue;
            }
            const numeric = try allocator.dupe(u8, std.mem.sliceTo(&address_buffer, 0));
            records.append(allocator, .{
                .address = numeric,
                .is_ipv6 = is_ipv6,
            }) catch |err| {
                allocator.free(numeric);
                return err;
            };
        }
        log.writef(.debug, "DNS resolved {s}: {} record(s)", .{
            log.sensitive(hostname),
            records.items.len,
        });
        return records.toOwnedSlice(allocator);
    }
};

pub const testing = struct {
    pub const C = c;
    pub const maxPendingQueries = max_pending_queries;

    pub fn pendingCount() usize {
        return query_pool.pendingCount();
    }

    pub fn resolveWith(
        resolver: *PlatformDNS,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(DNSResolver.Flag),
        reachability: ?ReachabilityInfo,
        timeout_ms: u32,
        resolve_fn: ResolveFn,
    ) DNSResolver.Error![]DNSRecord {
        return resolver.resolveWith(
            allocator,
            hostname,
            flags,
            reachability,
            timeout_ms,
            resolve_fn,
        );
    }
};

const QueryPool = struct {
    mutex: core.Mutex = .{},
    cond: core.Condition = .{},
    queries: [max_pending_queries]Query = [_]Query{.{}} ** max_pending_queries,

    fn acquire(
        self: *QueryPool,
        hostname: []const u8,
        all_addresses: bool,
        reachability: ?ReachabilityInfo,
        resolve_fn: ResolveFn,
    ) DNSResolver.Error!*Query {
        const hostname_copy = try std.heap.c_allocator.dupeZ(u8, hostname);
        errdefer std.heap.c_allocator.free(hostname_copy);

        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.queries) |*query| {
            if (query.in_use) continue;
            query.* = .{
                .in_use = true,
                .hostname = hostname_copy,
                .all_addresses = all_addresses,
                .reachability = reachability,
                .resolve_fn = resolve_fn,
            };
            return query;
        }
        log.write(.err, "DNS resolution rejected: too many pending queries");
        return error.Timeout;
    }

    fn releaseUnstarted(self: *QueryPool, query: *Query) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        query.caller_done = true;
        query.worker_done = true;
        query.recycleLocked();
    }

    fn pendingCount(self: *QueryPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.queries) |query| count += @intFromBool(query.in_use);
        return count;
    }
};

var query_pool: QueryPool = .{};

const Query = struct {
    in_use: bool = false,
    timed_out: bool = false,
    worker_done: bool = false,
    caller_done: bool = false,
    hostname: ?[:0]u8 = null,
    all_addresses: bool = false,
    reachability: ?ReachabilityInfo = null,
    resolve_fn: ResolveFn = resolveNative,
    status: c_int = 0,
    result: c.pp_dns_result = null,

    fn timeout(ctx: ?*anyopaque) void {
        const self: *Query = @ptrCast(@alignCast(ctx.?));
        query_pool.mutex.lock();
        defer query_pool.mutex.unlock();
        if (self.worker_done) return;
        self.timed_out = true;
        query_pool.cond.broadcast();
    }

    fn run(self: *Query) void {
        var result: c.pp_dns_result = null;
        var reachability = self.reachability;
        const status = self.resolve_fn(
            self.hostname.?,
            self.all_addresses,
            if (reachability) |*info| info else null,
            &result,
        );

        query_pool.mutex.lock();
        self.status = status;
        self.result = result;
        self.worker_done = true;
        query_pool.cond.broadcast();
        self.recycleLocked();
        query_pool.mutex.unlock();
    }

    fn recycleLocked(self: *Query) void {
        if (!self.caller_done or !self.worker_done) return;
        if (self.result) |result| c.pp_dns_free(result);
        std.heap.c_allocator.free(self.hostname.?);
        self.* = .{};
    }
};

fn resolveNative(
    hostname: [:0]const u8,
    all_addresses: bool,
    reachability: ?*const ReachabilityInfo,
    result: *c.pp_dns_result,
) c_int {
    return c.pp_dns_resolve(hostname.ptr, null, all_addresses, reachability, result);
}

fn resolveBlock(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    hostname: []const u8,
    flags: std.EnumSet(DNSResolver.Flag),
    reachability: ?ReachabilityInfo,
    timeout_ms: u32,
) DNSResolver.Error![]DNSRecord {
    const self: *PlatformDNS = @ptrCast(@alignCast(ptr.?));
    return self.resolve(allocator, hostname, flags, reachability, timeout_ms);
}

fn resolveAddressBlock(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    address: []const u8,
    reachability: ?ReachabilityInfo,
    timeout_ms: u32,
) DNSResolver.Error![]u8 {
    const self: *PlatformDNS = @ptrCast(@alignCast(ptr.?));
    return self.resolveAddress(allocator, address, reachability, timeout_ms);
}
