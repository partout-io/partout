// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const api = @import("api.zig");
const concurrency = @import("concurrency.zig");
const util = @import("util.zig");
const models = @import("logging_models.zig");

/// Log severity values exposed through the C ABI.
pub const Level = enum(c_int) {
    /// Broken invariant or failure of the logging/runtime subsystem.
    fault = 0,
    /// An operation failed; include the cause and owning connection.
    err = 1,
    /// Connection lifecycle milestones and concise negotiated summaries.
    notice = 2,
    /// Useful state transitions during normal operation.
    info = 3,
    /// Protocol traces and detailed diagnostics; never routine counters.
    debug = 4,
};

/// Immutable identity copied across asynchronous execution boundaries.
/// A scope is thread-local and must be restored before returning to a caller.
pub const Context = struct {
    profile_id: ?[36:0]u8 = null,

    pub fn init(profile_id: api.UUID) Context {
        var id: [36:0]u8 = @splat(0);
        @memcpy(&id, &profile_id);
        return .{ .profile_id = id };
    }

    pub fn enter(self: Context) Scope {
        const previous = current_context;
        current_context = self;
        return .{ .previous = previous };
    }
};

pub const Scope = struct {
    previous: Context,

    pub fn leave(self: Scope) void {
        current_context = self.previous;
    }
};

threadlocal var current_context: Context = .{};

pub fn currentContext() Context {
    return current_context;
}

const Logger = *const fn (
    ctx: ?*anyopaque,
    profile_id: ?[*:0]const u8,
    level: c_int,
    message: [*:0]const u8,
) callconv(.c) void;

/// Logger callback registered by the host application.
///
/// Profile UUID and unprefixed message are borrowed zero-terminated strings.
/// A null profile UUID denotes a global record.
pub const Callback = ?Logger;

var mutex: concurrency.Mutex = .{};
var logs_private_data: bool = false;
var max_level: Level = .debug;
var external_logger_ctx: ?*anyopaque = null;
var external_logger: Callback = null;

/// C ABI entry point used by foreign callers to forward a log message.
fn partoutLog(
    level: c_int,
    message: [*:0]const u8,
) callconv(.c) void {
    mutex.lock();
    if (level > @backingInt(max_level)) {
        mutex.unlock();
        return;
    }
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    const logger_ctx = external_logger_ctx;
    mutex.unlock();
    dispatchCString(logger, logger_ctx, level, message);
}

comptime {
    @export(&partoutLog, .{ .name = "partout_log" });
}

/// Configures global logging state.
///
/// `private_data` records whether callers permit sensitive values in logs.
/// Passing a null `logger` disables logging.
pub fn init(
    private_data: bool,
    logger: Callback,
    logger_ctx: ?*anyopaque,
) void {
    mutex.lock();
    logs_private_data = private_data;
    max_level = .debug;
    external_logger = logger;
    external_logger_ctx = logger_ctx;
    mutex.unlock();

    write(.notice, "Partout initialized");
}

/// Resets global logging state to its disabled defaults.
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    logs_private_data = false;
    max_level = .debug;
    external_logger_ctx = null;
    external_logger = null;
}

/// Changes accepted severity without replacing callback ownership or privacy.
pub fn setMaxLevel(level: Level) void {
    mutex.lock();
    defer mutex.unlock();
    max_level = level;
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

/// Marks a value as sensitive so `writef` applies the current privacy policy.
pub fn sensitive(value: anytype) SensitiveValue(@TypeOf(value)) {
    return .{ .value = value };
}

/// Writes a core log message.
///
/// The borrowed message remains valid for the duration of the callback.
pub fn write(level: Level, message: [:0]const u8) void {
    mutex.lock();
    if (@backingInt(level) > @backingInt(max_level)) {
        mutex.unlock();
        return;
    }
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    const logger_ctx = external_logger_ctx;
    mutex.unlock();
    dispatchSlice(logger, logger_ctx, @backingInt(level), message);
}

/// Formats and writes a core log message.
///
/// Registered models use compact public summaries, or full JSON with private
/// logging enabled. Sensitive values are otherwise replaced with `redacted_value`. Adapted arguments use the `{s}` format specifier. Rejected levels
/// return before allocating or invoking any formatting helpers.
pub fn writef(level: Level, comptime fmt: []const u8, args: anytype) void {
    mutex.lock();
    const private_data = logs_private_data;
    if (@backingInt(level) > @backingInt(max_level)) {
        mutex.unlock();
        return;
    }
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    const logger_ctx = external_logger_ctx;
    mutex.unlock();
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prepared = prepareArguments(
        allocator,
        args,
        private_data,
    ) catch return;
    const message = allocator.printSentinel(fmt, prepared, 0) catch return;
    dispatchSlice(logger, logger_ctx, @backingInt(level), message);
}

/// Forwards a borrowed C string directly to the configured C logger.
pub fn writeCString(level: Level, message: [*:0]const u8) void {
    const context = current_context;
    const profile_id: ?[*:0]const u8 = if (context.profile_id) |*id| id else null;
    writeCStringWithProfile(profile_id, level, message);
}

/// Forwards borrowed strings with explicit identity, without changing thread context.
/// A null profile ID denotes a global record. Strings live through the callback.
pub fn writeCStringWithProfile(profile_id: ?[*:0]const u8, level: Level, message: [*:0]const u8) void {
    mutex.lock();
    if (@backingInt(level) > @backingInt(max_level)) {
        mutex.unlock();
        return;
    }
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    const logger_ctx = external_logger_ctx;
    mutex.unlock();
    logger(logger_ctx, profile_id, @backingInt(level), message);
}

/// Logs a profile using the structured layout of the legacy Apple runtime.
pub fn writeProfile(level: Level, profile: *const api.Profile) void {
    writef(level, "\tID: {s}", .{profile.id});
    writef(level, "\tName: {s}", .{profile.name});
    if (profile.behavior) |behavior| {
        writef(level, "\tBehavior: {any}", .{behavior});
    }
    writeProfileModules(level, profile);
}

/// Logs the modules in a profile in their declared order.
///
/// The prefix matches the profile logging used by the legacy Apple runtime:
/// `+` denotes an active module and `-` an inactive one. Module descriptions
/// follow the configured private-data policy used by `writef`.
pub fn writeProfileModules(level: Level, profile: *const api.Profile) void {
    write(level, "\tModules:");
    for (profile.modules) |*module| {
        const prefix: [:0]const u8 = if (api.isActiveProfileModule(
            profile,
            api.moduleId(module),
        )) "+" else "-";
        switch (module.*) {
            .DNS => |*value| writeProfileModule(level, prefix, "DNSModule", value),
            .HTTPProxy => |*value| writeProfileModule(level, prefix, "HTTPProxyModule", value),
            .IP => |*value| writeProfileModule(level, prefix, "IPModule", value),
            .OnDemand => |*value| writeProfileModule(level, prefix, "OnDemandModule", value),
            .OpenVPN => |*value| writeProfileModule(level, prefix, "OpenVPNModule", value),
            .WireGuard => |*value| writeProfileModule(level, prefix, "WireGuardModule", value),
        }
    }
}

pub fn writeAndFailDebug(message: [:0]const u8) void {
    write(.err, message);
    if (builtin.mode == .debug) {
        @panic(message);
    }
}

pub fn writefAndFailDebug(comptime fmt: []const u8, args: anytype) void {
    writef(.err, fmt, args);
    if (builtin.mode == .debug) {
        std.debug.panic(fmt, args);
    }
}

fn dispatchSlice(
    logger: Logger,
    logger_ctx: ?*anyopaque,
    level: c_int,
    message: [:0]const u8,
) void {
    dispatchCString(logger, logger_ctx, level, message.ptr);
}

fn dispatchCString(
    logger: Logger,
    logger_ctx: ?*anyopaque,
    level: c_int,
    message: [*:0]const u8,
) void {
    const context = current_context;
    const profile_id: ?[*:0]const u8 = if (context.profile_id) |*id| id else null;
    logger(logger_ctx, profile_id, level, message);
}

fn writeProfileModule(
    level: Level,
    prefix: [:0]const u8,
    comptime name: [:0]const u8,
    value: anytype,
) void {
    writef(level, "\t\t{s} " ++ name ++ ": {s}", .{ prefix, value });
}

/// Writes a duration in seconds using a compact `h`, `m`, and `s`
/// representation.
pub fn logTimeSeconds(
    level: Level,
    comptime prefix: []const u8,
    seconds: f64,
) void {
    const ticks: u64 = if (seconds > 0) @intFromFloat(seconds) else 0;
    logTimeTicks(level, prefix, ticks);
}

/// Writes a duration in milliseconds using a compact `h`, `m`, and `s`
/// representation.
pub fn logTimeMs(
    level: Level,
    comptime prefix: []const u8,
    milliseconds: u64,
) void {
    logTimeTicks(level, prefix, milliseconds / 1000);
}

fn logTimeTicks(
    level: Level,
    comptime prefix: []const u8,
    ticks: u64,
) void {
    const hours = ticks / 3600;
    const minutes = (ticks % 3600) / 60;
    const seconds = ticks % 60;
    if (hours > 0 and minutes > 0 and seconds > 0) {
        writef(level, prefix ++ "{d}h{d}m{d}s", .{ hours, minutes, seconds });
    } else if (hours > 0 and minutes > 0) {
        writef(level, prefix ++ "{d}h{d}m", .{ hours, minutes });
    } else if (hours > 0 and seconds > 0) {
        writef(level, prefix ++ "{d}h{d}s", .{ hours, seconds });
    } else if (minutes > 0 and seconds > 0) {
        writef(level, prefix ++ "{d}m{d}s", .{ minutes, seconds });
    } else if (hours > 0) {
        writef(level, prefix ++ "{d}h", .{hours});
    } else if (minutes > 0) {
        writef(level, prefix ++ "{d}m", .{minutes});
    } else {
        writef(level, prefix ++ "{d}s", .{seconds});
    }
}

pub const redacted_value = "<redacted>";

fn SensitiveValue(comptime T: type) type {
    return struct {
        value: T,

        pub fn logging_formatter(
            allocator: std.mem.Allocator,
            wrapped: @This(),
        ) ![]const u8 {
            return formatExplicitSensitive(allocator, wrapped.value);
        }
    };
}

const ModelAdapter = models.Adapter;

const LogFormat = union(enum) {
    declared,
    model: ModelAdapter,
    optional,
    array,
    dictionary,
    dereference,
};

fn prepareArguments(
    allocator: std.mem.Allocator,
    args: anytype,
    private_data: bool,
) !PreparedArguments(@TypeOf(args)) {
    const Args = @TypeOf(args);
    const args_info = @typeInfo(Args).@"struct";
    var prepared: PreparedArguments(Args) = undefined;
    inline for (args_info.field_names, args_info.field_types) |name, FieldType| {
        const value = @field(args, name);
        @field(prepared, name) = if (comptime logFormat(FieldType) != null)
            if (!private_data and isSensitive(FieldType))
                redacted_value
            else
                try forLog(allocator, value, private_data)
        else
            value;
    }
    return prepared;
}

fn PreparedArguments(comptime Args: type) type {
    const args_info = @typeInfo(Args).@"struct";
    var names: [args_info.field_names.len][]const u8 = undefined;
    var types: [args_info.field_names.len]type = undefined;
    for (args_info.field_names, args_info.field_types, 0..) |name, FieldType, index| {
        names[index] = name;
        types[index] = if (logFormat(FieldType) != null)
            []const u8
        else
            runtimeType(FieldType);
    }
    if (args_info.is_tuple) return @Tuple(&types);
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn runtimeType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => i128,
        .comptime_float => f128,
        else => T,
    };
}

fn logFormat(comptime T: type) ?LogFormat {
    if (std.meta.hasFn(T, "logging_formatter")) return .declared;
    if (models.adapter(T)) |adapter| return .{ .model = adapter };
    return switch (@typeInfo(T)) {
        .optional => |optional| if (logFormat(optional.child) != null)
            .optional
        else
            null,
        .array => |array| if (isCollectionElement(array.child))
            .array
        else
            null,
        .pointer => |pointer| switch (pointer.size) {
            .one => if (logFormat(pointer.child) != null)
                .dereference
            else
                null,
            .slice => if (isCollectionElement(pointer.child)) .array else null,
            .many, .c => null,
        },
        .@"struct" => if (isDictionary(T)) .dictionary else null,
        else => null,
    };
}

fn isSensitive(comptime T: type) bool {
    if (models.adapter(T)) |adapter| return adapter != .summary;
    return switch (@typeInfo(T)) {
        .optional => |info| isSensitive(info.child),
        .pointer => |info| if (info.size == .one) isSensitive(info.child) else true,
        else => true,
    };
}

fn forLog(
    allocator: std.mem.Allocator,
    value: anytype,
    private_data: bool,
) ![]const u8 {
    const T = @TypeOf(value);
    const format = comptime logFormat(T) orelse
        @compileError("unsupported type passed to forLog()");
    return switch (format) {
        .declared => T.logging_formatter(allocator, value),
        .model => |adapter| formatWithAdapter(allocator, value, adapter, private_data),
        .optional => if (value) |unwrapped|
            forLog(allocator, unwrapped, private_data)
        else
            "null",
        .array => switch (@typeInfo(T)) {
            .array => formatArray(allocator, &value),
            .pointer => formatArray(allocator, value),
            else => @compileError("array log format requires an array or pointer type"),
        },
        .dictionary => formatDictionary(allocator, &value),
        .dereference => forLog(allocator, value.*, private_data),
    };
}

fn formatWithAdapter(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime adapter: ModelAdapter,
    private_data: bool,
) ![]const u8 {
    return switch (adapter) {
        .raw => value.raw,
        .raw_alloc => value.rawAlloc(allocator),
        .pem => value.pem,
        .hex => value.hexAlloc(allocator),
        .ip_settings => formatIPSettings(allocator, value),
        .summary => if (private_data) util.encodeJsonValue(allocator, value) else models.summary(allocator, value),
        .json => util.encodeJsonValue(allocator, value),
    };
}

fn formatExplicitSensitive(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]const u8 {
    const T = @TypeOf(value);
    if (comptime logFormat(T) != null) return forLog(allocator, value, true);
    if (comptime isString(T)) return allocator.dupe(u8, value);
    return allocator.print("{any}", .{value});
}

fn formatIPSettings(
    allocator: std.mem.Allocator,
    value: api.IPSettings,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("addrs ");
    try writeArray(writer, allocator, value.subnets);
    try writer.writeAll(", includedRoutes=");
    try writeArray(writer, allocator, value.included_routes);
    try writer.writeAll(", excludedRoutes=");
    try writeArray(writer, allocator, value.excluded_routes);
    return output.toOwnedSlice();
}

fn formatArray(
    allocator: std.mem.Allocator,
    values: anytype,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeArray(&output.writer, allocator, values);
    return output.toOwnedSlice();
}

fn writeArray(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    values: anytype,
) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeDebug(writer, allocator, value);
    }
    try writer.writeByte(']');
}

fn formatDictionary(
    allocator: std.mem.Allocator,
    dictionary: anytype,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeByte('[');
    var iterator = dictionary.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (index > 0) try writer.writeAll(", ");
        try writeDebug(writer, allocator, entry.key_ptr.*);
        try writer.writeAll(": ");
        try writeDebug(writer, allocator, entry.value_ptr.*);
    }
    try writer.writeByte(']');
    return output.toOwnedSlice();
}

fn writeDebug(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    if (comptime logFormat(@TypeOf(value)) != null) {
        try writer.writeAll(try forLog(allocator, value, true));
    } else if (comptime isString(@TypeOf(value))) {
        try writer.writeAll(value);
    } else {
        try writer.print("{any}", .{value});
    }
}

fn isCollectionElement(comptime T: type) bool {
    return logFormat(T) != null or isString(T);
}

fn isDictionary(comptime T: type) bool {
    if (!std.meta.hasFn(T, "iterator") or !@hasDecl(T, "Entry")) return false;
    return @hasField(T.Entry, "key_ptr") and @hasField(T.Entry, "value_ptr");
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |array| array.child == u8,
        .pointer => |pointer| switch (pointer.size) {
            .one => @typeInfo(pointer.child) == .array and
                @typeInfo(pointer.child).array.child == u8,
            .slice => pointer.child == u8,
            .many, .c => false,
        },
        else => false,
    };
}
