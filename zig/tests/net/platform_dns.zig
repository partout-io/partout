// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const platform_dns = source.net_platform_dns;
const c = platform_dns.testing.C;
const PlatformDNS = platform_dns.PlatformDNS;
const ReachabilityInfo = source.net_io.ReachabilityInfo;

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
    const max_pending_queries = platform_dns.testing.maxPendingQueries;
    var dns = PlatformDNS.init();
    HangingResolver.release.store(false, .release);
    defer {
        HangingResolver.release.store(true, .release);
        while (platform_dns.testing.pendingCount() != 0) std.Thread.yield() catch {};
    }

    for (0..max_pending_queries) |_| {
        try std.testing.expectError(error.Timeout, platform_dns.testing.resolveWith(
            &dns,
            allocator,
            "example.com",
            .initEmpty(),
            null,
            1,
            HangingResolver.resolve,
        ));
    }
    try std.testing.expectEqual(max_pending_queries, platform_dns.testing.pendingCount());
    try std.testing.expectError(error.Timeout, platform_dns.testing.resolveWith(
        &dns,
        allocator,
        "example.com",
        .initEmpty(),
        null,
        1,
        HangingResolver.resolve,
    ));
    try std.testing.expectEqual(max_pending_queries, platform_dns.testing.pendingCount());

    HangingResolver.release.store(true, .release);
    while (platform_dns.testing.pendingCount() != 0) std.Thread.yield() catch {};
    try std.testing.expectError(error.ResolutionFailure, platform_dns.testing.resolveWith(
        &dns,
        allocator,
        "example.com",
        .initEmpty(),
        null,
        100,
        HangingResolver.resolve,
    ));
    try std.testing.expectEqual(@as(usize, 0), platform_dns.testing.pendingCount());
}
