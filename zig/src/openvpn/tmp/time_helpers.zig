// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const time_c = @cImport(@cInclude("time.h"));

pub fn unixSeconds() u32 {
    const raw = time_c.time(null);
    if (raw <= 0) return 0;
    return @truncate(@as(u64, @intCast(raw)));
}

pub fn wallMilliseconds() i64 {
    var value: time_c.timespec = undefined;
    if (time_c.timespec_get(&value, time_c.TIME_UTC) != time_c.TIME_UTC) return 0;
    const seconds = std.math.mul(i64, @intCast(value.tv_sec), 1000) catch return std.math.maxInt(i64);
    return std.math.add(i64, seconds, @divTrunc(@as(i64, @intCast(value.tv_nsec)), 1_000_000)) catch std.math.maxInt(i64);
}

test "wall clock helpers return plausible values" {
    try std.testing.expect(unixSeconds() > 1_000_000_000);
    try std.testing.expect(wallMilliseconds() > 1_000_000_000_000);
}
