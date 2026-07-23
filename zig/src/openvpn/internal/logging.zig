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
