// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const concurrency = @import("concurrency.zig");
const util = @import("util.zig");

/// Log severity values exposed through the C ABI.
pub const Level = enum(c_int) {
    fault = 0,
    err = 1,
    notice = 2,
    info = 3,
    debug = 4,
};

// ZIGME: Suppress until only Zig ABI
/// C ABI entry point used by foreign callers to forward a log message.
// pub export fn partout_log(
//     level: c_int,
//     message: [*:0]const u8,
// ) callconv(.c) void {
//     dispatch(level, message);
// }

var mutex: concurrency.Mutex = .{};
var logs_private_data: bool = false;
var external_logger: Callback = null;

/// Logger callback registered by the host application.
///
/// `message` must be a zero-terminated string.
pub const Callback = ?*const fn (
    level: c_int,
    message: [*:0]const u8,
) callconv(.c) void;

/// Configures global logging state.
///
/// `private_data` records whether callers permit sensitive values in logs.
/// Passing a null `logger` disables logging.
pub fn init(
    private_data: bool,
    logger: Callback,
) void {
    mutex.lock();
    defer mutex.unlock();
    logs_private_data = private_data;
    external_logger = logger;
}

/// Resets global logging state to its disabled defaults.
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    logs_private_data = false;
    external_logger = null;
}

/// Reports whether logging sensitive values is currently allowed.
pub fn logsPrivateData() bool {
    mutex.lock();
    defer mutex.unlock();
    return logs_private_data;
}

/// Reports whether a host logger callback is currently installed.
pub fn hasLogger() bool {
    mutex.lock();
    defer mutex.unlock();
    return external_logger != null;
}

/// Writes a core log message.
///
/// Messages are dropped when no logger is installed or when allocating the
/// zero-terminated copy fails.
pub fn write(level: Level, message: []const u8) void {
    const allocator = std.heap.c_allocator;
    var c_message: util.TemporaryCString = .{};
    c_message.init(allocator, message) catch return;
    defer c_message.deinit();
    dispatch(@intFromEnum(level), c_message.ptr());
}

/// Formats and writes a core log message.
pub fn writef(level: Level, comptime fmt: []const u8, args: anytype) void {
    const allocator = std.heap.c_allocator;
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(message);
    write(level, message);
}

fn dispatch(level: c_int, message: [*:0]const u8) void {
    mutex.lock();
    // Copy the callback under the lock, then invoke it outside the lock so
    // loggers can call back into this API.
    const logger = external_logger;
    if (logger == null) {
        mutex.unlock();
        return;
    }
    mutex.unlock();

    logger.?(level, message);
}
