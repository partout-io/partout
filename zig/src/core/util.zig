// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const TemporaryCString = TemporaryCStringWithCapacity(256);

/// Scope-bound zero-terminated copy for passing Zig strings to C APIs.
///
/// Small values are stored in this object. Larger values fall back to
/// `fallback_allocator`. Do not copy the object after `init`; call `deinit`
/// before it leaves scope.
pub fn TemporaryCStringWithCapacity(comptime capacity: usize) type {
    return struct {
        stack_allocator: std.heap.StackFallbackAllocator(capacity) = undefined,
        allocator: std.mem.Allocator = undefined,
        value: ?[:0]u8 = null,

        const Self = @This();

        pub fn init(
            self: *Self,
            fallback_allocator: std.mem.Allocator,
            value: []const u8,
        ) error{OutOfMemory}!void {
            std.debug.assert(self.value == null);

            self.stack_allocator = std.heap.stackFallback(capacity, fallback_allocator);
            self.allocator = self.stack_allocator.get();
            self.value = try self.allocator.dupeSentinel(u8, value, 0);
        }

        pub fn deinit(self: *Self) void {
            if (self.value) |value| {
                self.allocator.free(value);
                self.value = null;
            }
        }

        pub fn slice(self: *const Self) [:0]const u8 {
            return self.value.?;
        }

        pub fn ptr(self: *const Self) [*:0]const u8 {
            return self.slice().ptr;
        }
    };
}

/// Appends an allocator-owned copy of `value` to `list`.
///
/// The list owns the appended copy and should be released with
/// `deinitListOfStrings` or equivalent cleanup.
pub fn appendOwned(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
    value: []const u8,
) error{OutOfMemory}!void {
    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
}

/// Returns a slice from a C string.
pub fn borrowedCString(ptr: [*:0]const u8) []const u8 {
    return std.mem.span(ptr);
}

/// Deep-copies a slice of owned strings.
///
/// The returned slice and each string inside it are allocated with `allocator`.
pub fn cloneSliceOfStrings(allocator: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}![][]u8 {
    const out = try allocator.alloc([]u8, lines.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |line| allocator.free(line);
        allocator.free(out);
    }
    for (lines, 0..) |line, index| {
        out[index] = try allocator.dupe(u8, line);
        initialized += 1;
    }
    return out;
}

/// Returns true when every byte in `value` is present in `allowed`.
pub fn containsOnly(value: []const u8, allowed: []const u8) bool {
    for (value) |byte| {
        if (std.mem.indexOfScalar(u8, allowed, byte) == null) return false;
    }
    return true;
}

/// Returns an allocator-owned path to the system temporary directory.
pub fn defaultCacheDir(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const env_names = [_][*:0]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (env_names) |name| {
        const value = std.c.getenv(name) orelse continue;
        const path = std.mem.span(value);
        if (path.len > 0) return allocator.dupe(u8, path);
    }
    return allocator.dupe(u8, "/tmp");
}

/// Calls `deinit` on every item in a list, then deinitializes the list.
pub fn deinitList(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(T),
) void {
    for (list.items) |*item| item.deinit(allocator);
    list.deinit(allocator);
}

/// Frees every owned string in `list`, then deinitializes the list itself.
pub fn deinitListOfStrings(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

pub fn deinitSliceOfStrings(
    allocator: std.mem.Allocator,
    list: [][]u8,
) void {
    for (list) |item| allocator.free(item);
    list.deinit(allocator);
}

/// Encodes any JSON-stringifiable value into an allocated buffer.
///
/// The caller owns the returned buffer.
pub fn encodeJsonValue(
    allocator: std.mem.Allocator,
    value: anytype,
) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Encodes any JSON-stringifiable value into an allocated, null-terminated buffer.
///
/// The caller owns the returned buffer.
pub fn encodeJsonValueZ(
    allocator: std.mem.Allocator,
    value: anytype,
) error{OutOfMemory}![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(value, .{}, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSliceSentinel(0);
}

/// Calls `deinit` on every item in an owned slice, then frees the slice.
pub fn freeSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
) void {
    for (items) |item| {
        var mutable = item;
        mutable.deinit(allocator);
    }
    if (items.len > 0) allocator.free(items);
}

/// Frees every owned string in `items`, then frees the slice storage.
pub fn freeSliceOfStrings(
    allocator: std.mem.Allocator,
    items: [][]u8,
) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

/// Performs a lightweight syntactic check for IP address-like strings.
///
/// This is intentionally not full IP validation; it only rejects inputs that
/// contain characters impossible in IPv4 or IPv6 literals.
pub fn isLikelyIPAddress(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.indexOfScalar(u8, value, ':') != null) {
        return containsOnly(value, "0123456789abcdefABCDEF:.");
    }
    return containsOnly(value, "0123456789.");
}

/// Converts an array of C string pointers to an owned array of owned strings.
pub fn ownedSliceOfCStrings(
    allocator: std.mem.Allocator,
    ptrs: ?[*]?[*:0]const u8,
    count: usize,
) error{OutOfMemory}![][]u8 {
    const values = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| allocator.free(value);
        allocator.free(values);
    }
    for (values, 0..) |*value, i| {
        const source = if (ptrs) |list|
            if (list[i]) |item| std.mem.span(item) else ""
        else
            "";
        value.* = try allocator.dupe(u8, source);
        initialized += 1;
    }
    return values;
}

/// Compares optional borrowed strings by presence and byte equality.
pub fn optionalStringsEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

/// Parses JSON into a generic value tree.
///
/// Numeric values are preserved as strings so schema parsers can decide how to
/// coerce them later. The returned parsed value owns memory and must be
/// deinitialized by the caller.
pub fn parseJsonValue(
    allocator: std.mem.Allocator,
    text: []const u8,
) error{ InvalidJson, OutOfMemory }!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        text,
        .{ .parse_numbers = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

/// Replaces an optional owned string field, freeing the previous value first.
///
/// Ownership of `value` is transferred to `field`.
pub fn replaceOwned(allocator: std.mem.Allocator, field: *?[]const u8, value: []u8) void {
    if (field.*) |old| allocator.free(old);
    field.* = value;
}

/// Trims common ASCII whitespace from both ends of `value`.
pub fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \r\t\n");
}

/// Runs a callback with a slice temporarily remapped to a C string.
pub fn withCString(
    value: []const u8,
    callback: *const fn (?*anyopaque, [*c]const u8) callconv(.c) void,
    callback_ctx: ?*anyopaque,
) void {
    var c_value: TemporaryCString = .{};
    c_value.init(std.heap.c_allocator, value) catch return;
    defer c_value.deinit();
    callback(callback_ctx, c_value.ptr());
}
