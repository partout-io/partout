// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const gen = @import("api_generated.zig");
const manual = @import("api_manual.zig");
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

const Logger = *const fn (
    level: c_int,
    message: [*:0]const u8,
) callconv(.c) void;

/// Logger callback registered by the host application.
///
/// `message` must be a zero-terminated string.
pub const Callback = ?Logger;

var mutex: concurrency.Mutex = .{};
var logs_private_data: bool = false;
var external_logger: Callback = null;

// ZIGME: Suppress until only Zig ABI
/// C ABI entry point used by foreign callers to forward a log message.
// pub export fn partout_log(
//     level: c_int,
//     message: [*:0]const u8,
// ) callconv(.c) void {
//     mutex.lock();
//     const logger = external_logger orelse {
//         mutex.unlock();
//         return;
//     };
//     mutex.unlock();
//     dispatch(logger, level, message);
// }

fn dispatch(
    logger: Logger,
    level: c_int,
    message: [*:0]const u8,
) void {
    logger(level, message);
}

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

/// Marks a value as sensitive so `writef` applies the current privacy policy.
pub fn sensitive(value: anytype) SensitiveValue(@TypeOf(value)) {
    return .{ .value = value };
}

/// Writes a core log message.
///
/// Messages are dropped when no logger is installed or when allocating the
/// zero-terminated copy fails.
pub fn write(level: Level, message: []const u8) void {
    mutex.lock();
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    mutex.unlock();
    writeTo(logger, level, message);
}

fn writeTo(logger: Logger, level: Level, message: []const u8) void {
    const allocator = std.heap.c_allocator;
    var c_message: util.TemporaryCString = .{};
    c_message.init(allocator, message) catch return;
    defer c_message.deinit();
    dispatch(logger, @intFromEnum(level), c_message.ptr());
}

/// Formats and writes a core log message.
///
/// Arguments with a registered logging representation are replaced with
/// `redacted_value` unless private logging is enabled. Otherwise, their debug
/// representation is substituted into the format arguments. Privacy-aware
/// arguments therefore use the `{s}` format specifier.
pub fn writef(level: Level, comptime fmt: []const u8, args: anytype) void {
    mutex.lock();
    const private_data = logs_private_data;
    const logger = external_logger orelse {
        mutex.unlock();
        return;
    };
    mutex.unlock();
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prepared = prepareArguments(
        allocator,
        args,
        private_data,
    ) catch return;
    const message = std.fmt.allocPrint(allocator, fmt, prepared) catch return;
    writeTo(logger, level, message);
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

const redacted_value = "<redacted>";

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

const ModelAdapter = enum {
    raw,
    raw_alloc,
    pem,
    hex,
    ip_settings,
    json,
};

const LogFormat = union(enum) {
    declared,
    model: ModelAdapter,
    optional,
    array,
    dictionary,
    dereference,
};

// API models cannot retroactively declare a logging formatter. Keep their
// type identity and representation together in this comptime adapter registry.
const model_adapters = .{
    .{ manual.Address, ModelAdapter.raw },
    .{ manual.Endpoint, ModelAdapter.raw_alloc },
    .{ manual.ExtendedEndpoint, ModelAdapter.raw_alloc },
    .{ manual.OpenVPNCryptoContainer, ModelAdapter.pem },
    .{ manual.SecureData, ModelAdapter.hex },
    .{ manual.Subnet, ModelAdapter.raw_alloc },
    .{ manual.WireGuardKey, ModelAdapter.raw },
    .{ gen.IPSettings, ModelAdapter.ip_settings },
    .{ gen.DNSModule, ModelAdapter.json },
    .{ gen.DNSModuleProtocolType, ModelAdapter.json },
    .{ gen.DNSModuleProtocolTypeHttps, ModelAdapter.json },
    .{ gen.DNSModuleProtocolTypeTls, ModelAdapter.json },
    .{ gen.HTTPProxyModule, ModelAdapter.json },
    .{ gen.IPModule, ModelAdapter.json },
    .{ gen.OnDemandModule, ModelAdapter.json },
    .{ gen.OpenVPNConfiguration, ModelAdapter.json },
    .{ gen.OpenVPNCredentials, ModelAdapter.json },
    .{ gen.OpenVPNModule, ModelAdapter.json },
    .{ gen.OpenVPNObfuscationMethod, ModelAdapter.json },
    .{ gen.OpenVPNObfuscationMethodObfuscate, ModelAdapter.json },
    .{ gen.OpenVPNObfuscationMethodXormask, ModelAdapter.json },
    .{ gen.OpenVPNStaticKey, ModelAdapter.json },
    .{ gen.OpenVPNTLSWrap, ModelAdapter.json },
    .{ gen.Profile, ModelAdapter.json },
    .{ gen.Route, ModelAdapter.json },
    .{ gen.TaggedModule, ModelAdapter.json },
    .{ gen.TunnelControllerOptions, ModelAdapter.json },
    .{ gen.TunnelRemoteInfoWrapper, ModelAdapter.json },
    .{ gen.WireGuardConfiguration, ModelAdapter.json },
    .{ gen.WireGuardLocalInterface, ModelAdapter.json },
    .{ gen.WireGuardModule, ModelAdapter.json },
    .{ gen.WireGuardRemoteInterface, ModelAdapter.json },
};

fn prepareArguments(
    allocator: std.mem.Allocator,
    args: anytype,
    private_data: bool,
) !PreparedArguments(@TypeOf(args)) {
    const Args = @TypeOf(args);
    const args_info = @typeInfo(Args).@"struct";
    var prepared: PreparedArguments(Args) = undefined;
    inline for (args_info.fields) |field| {
        const value = @field(args, field.name);
        @field(prepared, field.name) = if (comptime logFormat(field.type) != null)
            if (private_data)
                try forLog(allocator, value)
            else
                redacted_value
        else
            value;
    }
    return prepared;
}

fn PreparedArguments(comptime Args: type) type {
    const args_info = @typeInfo(Args).@"struct";
    var names: [args_info.fields.len][]const u8 = undefined;
    var types: [args_info.fields.len]type = undefined;
    for (args_info.fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = if (logFormat(field.type) != null)
            []const u8
        else
            runtimeType(field.type);
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
    if (findModelAdapter(T)) |adapter| return .{ .model = adapter };
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

fn forLog(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]const u8 {
    const T = @TypeOf(value);
    const format = comptime logFormat(T) orelse unreachable;
    return switch (format) {
        .declared => T.logging_formatter(allocator, value),
        .model => |adapter| formatWithAdapter(allocator, value, adapter),
        .optional => if (value) |unwrapped|
            forLog(allocator, unwrapped)
        else
            "null",
        .array => switch (@typeInfo(T)) {
            .array => formatArray(allocator, &value),
            .pointer => formatArray(allocator, value),
            else => unreachable,
        },
        .dictionary => formatDictionary(allocator, &value),
        .dereference => forLog(allocator, value.*),
    };
}

fn findModelAdapter(comptime T: type) ?ModelAdapter {
    inline for (model_adapters) |adapter| {
        if (T == adapter[0]) return adapter[1];
    }
    return null;
}

fn formatWithAdapter(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime adapter: ModelAdapter,
) ![]const u8 {
    return switch (adapter) {
        .raw => value.raw,
        .raw_alloc => value.rawAlloc(allocator),
        .pem => value.pem,
        .hex => value.hexAlloc(allocator),
        .ip_settings => formatIPSettings(allocator, value),
        .json => util.encodeJsonValue(allocator, value),
    };
}

fn formatExplicitSensitive(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]const u8 {
    const T = @TypeOf(value);
    if (comptime logFormat(T) != null) return forLog(allocator, value);
    if (comptime isString(T)) return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "{any}", .{value});
}

fn formatIPSettings(
    allocator: std.mem.Allocator,
    value: gen.IPSettings,
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
        try writer.writeAll(try forLog(allocator, value));
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
