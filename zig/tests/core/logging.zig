// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const logging = @import("source").core_logging;

test "private data flag round-trips" {
    logging.init(true, null);
    defer logging.deinit();
    try std.testing.expect(logging.logsPrivateData());
}

test "logging is disabled without callback" {
    logging.init(false, null);
    defer logging.deinit();
    try std.testing.expect(!logging.hasLogger());
    logging.write(.notice, "ignored");
}

test "external logger callback receives log messages" {
    const TestLogger = struct {
        var called = false;
        var saw_level = false;
        var saw_message = false;

        fn log(level: c_int, message: [*:0]const u8) callconv(.c) void {
            called = true;
            saw_level = level == @intFromEnum(logging.Level.notice);
            saw_message = std.mem.eql(u8, std.mem.span(message), "hello");
        }
    };

    logging.init(false, TestLogger.log);
    defer logging.deinit();

    logging.write(.notice, "hello");

    try std.testing.expect(TestLogger.called);
    try std.testing.expect(TestLogger.saw_level);
    try std.testing.expect(TestLogger.saw_message);
}
