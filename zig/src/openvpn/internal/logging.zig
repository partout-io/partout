// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core_mod = @import("../../core/exports.zig");

const log = core_mod.logging;

pub fn sensitiveString(
    level: log.Level,
    comptime prefix: []const u8,
    value: []const u8,
) void {
    log.writef(level, prefix ++ "{s}", .{
        if (log.logsPrivateData()) value else "<redacted>",
    });
}

pub fn timeSeconds(
    level: log.Level,
    comptime prefix: []const u8,
    seconds: f64,
) void {
    const ticks: u64 = if (seconds > 0) @intFromFloat(seconds) else 0;
    timeTicks(level, prefix, ticks);
}

pub fn timeMilliseconds(
    level: log.Level,
    comptime prefix: []const u8,
    milliseconds: u64,
) void {
    timeTicks(level, prefix, milliseconds / 1000);
}

fn timeTicks(
    level: log.Level,
    comptime prefix: []const u8,
    ticks: u64,
) void {
    const hours = ticks / 3600;
    const minutes = (ticks % 3600) / 60;
    const seconds = ticks % 60;
    if (hours > 0 and minutes > 0 and seconds > 0) {
        log.writef(level, prefix ++ "{d}h{d}m{d}s", .{ hours, minutes, seconds });
    } else if (hours > 0 and minutes > 0) {
        log.writef(level, prefix ++ "{d}h{d}m", .{ hours, minutes });
    } else if (hours > 0 and seconds > 0) {
        log.writef(level, prefix ++ "{d}h{d}s", .{ hours, seconds });
    } else if (minutes > 0 and seconds > 0) {
        log.writef(level, prefix ++ "{d}m{d}s", .{ minutes, seconds });
    } else if (hours > 0) {
        log.writef(level, prefix ++ "{d}h", .{hours});
    } else if (minutes > 0) {
        log.writef(level, prefix ++ "{d}m", .{minutes});
    } else {
        log.writef(level, prefix ++ "{d}s", .{seconds});
    }
}
