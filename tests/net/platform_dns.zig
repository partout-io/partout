// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const logging = source.core_logging;
const platform_dns = source.net_platform_dns;
const io_c = source.net_io.io_c;
const PlatformDNS = platform_dns.PlatformDNS;
const ReachabilityInfo = source.net_io.ReachabilityInfo;

const CapturingLogger = struct {
    var message: [256]u8 = undefined;
    var message_len: usize = 0;

    fn log(_: ?*anyopaque, _: c_int, raw_message: [*:0]const u8) callconv(.c) void {
        const value = std.mem.span(raw_message);
        message_len = @min(value.len, message.len);
        @memcpy(message[0..message_len], value[0..message_len]);
    }

    fn lastMessage() []const u8 {
        return message[0..message_len];
    }
};

test "DNS resolver times out and caps abandoned queries" {
    const HangingResolver = struct {
        var release = std.atomic.Value(bool).init(false);

        fn resolve(
            _: [:0]const u8,
            _: bool,
            _: ?*const ReachabilityInfo,
            _: *io_c.pp_dns_result,
        ) c_int {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            return -1;
        }
    };

    const allocator = std.testing.allocator;
    const max_pending_queries = platform_dns.testing.maxPendingQueries;
    var dns = PlatformDNS.init();
    logging.init(false, null, CapturingLogger.log);
    defer logging.deinit();
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
    try std.testing.expectEqualStrings(
        "DNS resolution timed out for <redacted>",
        CapturingLogger.lastMessage(),
    );
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
