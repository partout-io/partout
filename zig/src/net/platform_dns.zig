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
const ResolveFn = *const fn ([*:0]const u8, *const c.addrinfo, ?*const ReachabilityInfo, *[*c]c.addrinfo) c_int;

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
        self: *PlatformDNS,
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
        self: *PlatformDNS,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(DNSResolver.Flag),
        reachability: ?ReachabilityInfo,
        timeout_ms: u32,
    ) DNSResolver.Error![]DNSRecord {
        return self.resolveWith(allocator, hostname, flags, reachability, timeout_ms, resolveNative);
    }

    fn resolveWith(
        _: *PlatformDNS,
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

        const query = query_pool.acquire(hostname, .{
            .ai_family = c.AF_UNSPEC,
            .ai_flags = dnsFlags(flags),
        }, reachability, resolve_fn) catch |err| return err;

        var timer: core.RunAfter = .{};
        timer.init(timeout_ms, Query.timeout, query) catch |err| {
            timer.deinit();
            query_pool.releaseUnstarted(query);
            log.writef(.err, "Unable to start DNS timeout: {}", .{err});
            return if (err == error.OutOfMemory) error.OutOfMemory else error.ResolutionFailure;
        };

        const thread = std.Thread.spawn(.{}, Query.run, .{query}) catch |err| {
            timer.cancel();
            timer.deinit();
            query_pool.releaseUnstarted(query);
            log.writef(.err, "Unable to start DNS resolution: {}", .{err});
            return if (err == error.OutOfMemory) error.OutOfMemory else error.ResolutionFailure;
        };

        query_pool.mutex.lock();
        while (!query.worker_done and !query.timed_out) query_pool.cond.wait(&query_pool.mutex);
        const timed_out = query.timed_out;
        const status = query.status;
        var result: [*c]c.addrinfo = null;
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
            log.writef(.err, "DNS resolution timed out for {s}", .{hostname});
            return error.Timeout;
        }
        thread.join();

        defer if (result) |info| c.freeaddrinfo(info);
        if (status != 0) {
            if (@hasDecl(c, "EAI_BADFLAGS") and status == c.EAI_BADFLAGS) {
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
        while (item) |info| : (item = info.*.ai_next) {
            const current = info.*;
            const addr = current.ai_addr;
            if (addr == null) continue;
            const numeric = numericHostAlloc(allocator, addr, current.ai_addrlen) catch |err| {
                log.writef(.err, "getnameinfo() failed for {s}: {}", .{ hostname, err });
                continue;
            };
            records.append(allocator, .{
                .address = numeric,
                .is_ipv6 = current.ai_family == c.AF_INET6,
            }) catch |err| {
                allocator.free(numeric);
                return err;
            };
        }
        log.writef(.debug, "DNS resolved {s}: {} record(s)", .{ hostname, records.items.len });
        return records.toOwnedSlice(allocator);
    }
};

const QueryPool = struct {
    mutex: core.Mutex = .{},
    cond: core.Condition = .{},
    queries: [max_pending_queries]Query = [_]Query{.{}} ** max_pending_queries,

    fn acquire(
        self: *QueryPool,
        hostname: []const u8,
        hints: c.addrinfo,
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
                .hints = hints,
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
    hints: c.addrinfo = .{},
    reachability: ?ReachabilityInfo = null,
    resolve_fn: ResolveFn = resolveNative,
    status: c_int = 0,
    result: [*c]c.addrinfo = null,

    fn timeout(ctx: ?*anyopaque) void {
        const self: *Query = @ptrCast(@alignCast(ctx.?));
        query_pool.mutex.lock();
        defer query_pool.mutex.unlock();
        if (self.worker_done) return;
        self.timed_out = true;
        query_pool.cond.broadcast();
    }

    fn run(self: *Query) void {
        var result: [*c]c.addrinfo = null;
        var reachability = self.reachability;
        const status = self.resolve_fn(
            self.hostname.?,
            &self.hints,
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
        if (self.result) |result| c.freeaddrinfo(result);
        std.heap.c_allocator.free(self.hostname.?);
        self.* = .{};
    }
};

fn resolveNative(
    hostname: [*:0]const u8,
    hints: *const c.addrinfo,
    reachability: ?*const ReachabilityInfo,
    result: *[*c]c.addrinfo,
) c_int {
    return c.pp_dns_resolve(hostname, null, hints, reachability, result);
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

fn dnsFlags(flags: std.EnumSet(DNSResolver.Flag)) c_int {
    var result: c_int = 0;
    // Beware that DNS breaks on Android when AI_ALL + AF_UNSPEC is set
    if (builtin.os.tag.isDarwin()) {
        if (flags.contains(.allAddresses) and @hasDecl(c, "AI_ALL")) {
            result |= c.AI_ALL;
        }
    }
    return result;
}

fn numericHostAlloc(
    allocator: std.mem.Allocator,
    addr: [*c]const c.struct_sockaddr,
    addr_len: c.socklen_t,
) DNSResolver.Error![]u8 {
    var buffer: [c.NI_MAXHOST]u8 = [_]u8{0} ** c.NI_MAXHOST;
    switch (c.getnameinfo(
        addr,
        addr_len,
        buffer[0..].ptr,
        @intCast(buffer.len),
        null,
        0,
        c.NI_NUMERICHOST,
    )) {
        0 => {},
        else => return error.ResolutionFailure,
    }
    return try allocator.dupe(u8, std.mem.sliceTo(&buffer, 0));
}

test "DNS resolver times out and caps abandoned queries" {
    const HangingResolver = struct {
        var release = std.atomic.Value(bool).init(false);

        fn resolve(
            _: [*:0]const u8,
            _: *const c.addrinfo,
            _: ?*const ReachabilityInfo,
            _: *[*c]c.addrinfo,
        ) c_int {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            return -1;
        }
    };

    const allocator = std.testing.allocator;
    var dns = PlatformDNS.init();
    HangingResolver.release.store(false, .release);
    defer {
        HangingResolver.release.store(true, .release);
        while (query_pool.pendingCount() != 0) std.Thread.yield() catch {};
    }

    for (0..max_pending_queries) |_| {
        try std.testing.expectError(error.Timeout, dns.resolveWith(
            allocator,
            "example.com",
            .initEmpty(),
            null,
            1,
            HangingResolver.resolve,
        ));
    }
    try std.testing.expectEqual(max_pending_queries, query_pool.pendingCount());
    try std.testing.expectError(error.Timeout, dns.resolveWith(
        allocator,
        "example.com",
        .initEmpty(),
        null,
        1,
        HangingResolver.resolve,
    ));
    try std.testing.expectEqual(max_pending_queries, query_pool.pendingCount());

    HangingResolver.release.store(true, .release);
    while (query_pool.pendingCount() != 0) std.Thread.yield() catch {};
    try std.testing.expectError(error.ResolutionFailure, dns.resolveWith(
        allocator,
        "example.com",
        .initEmpty(),
        null,
        100,
        HangingResolver.resolve,
    ));
    try std.testing.expectEqual(@as(usize, 0), query_pool.pendingCount());
}
