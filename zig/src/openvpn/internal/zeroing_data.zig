// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_common = @import("../../c/exports.zig").common;
const errors = @import("errors.zig");

/// Owning Zig facade over the existing C `pp_zd` implementation.
///
/// This intentionally does not reimplement the C zeroing buffer. All storage,
/// resizing, slicing, prefix removal, wiping, and release are delegated to the
/// existing portable C code, matching Swift's `CZeroingData` wrapper.
pub const ZeroingData = struct {
    ptr: ?*c_common.pp_zd = null,
    bytes: []u8 = @constCast(&[_]u8{}),

    pub fn init(_: std.mem.Allocator, count: usize) std.mem.Allocator.Error!ZeroingData {
        return fromC(c_common.pp_zd_create(count));
    }

    pub fn initCopy(
        _: std.mem.Allocator,
        source: []const u8,
    ) std.mem.Allocator.Error!ZeroingData {
        return fromC(c_common.pp_zd_create_from_data(source.ptr, source.len));
    }

    pub fn initString(
        _: std.mem.Allocator,
        source: []const u8,
        null_terminated: bool,
    ) std.mem.Allocator.Error!ZeroingData {
        const length = source.len + @intFromBool(null_terminated);
        var result = fromC(c_common.pp_zd_create(length));
        @memcpy(result.bytes[0..source.len], source);
        if (null_terminated) result.bytes[source.len] = 0;
        return result;
    }

    pub fn fromC(ptr: *c_common.pp_zd) ZeroingData {
        return .{
            .ptr = ptr,
            .bytes = ptr.*.bytes[0..ptr.*.length],
        };
    }

    pub fn clone(self: ZeroingData, _: std.mem.Allocator) std.mem.Allocator.Error!ZeroingData {
        return fromC(c_common.pp_zd_make_copy(self.cPtr()));
    }

    pub fn deinit(self: *ZeroingData, _: std.mem.Allocator) void {
        if (self.ptr) |ptr| c_common.pp_zd_free(ptr);
        self.* = .{};
    }

    pub fn move(self: *ZeroingData) ZeroingData {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn cPtr(self: ZeroingData) *c_common.pp_zd {
        return self.ptr orelse @panic("use of deinitialized ZeroingData");
    }

    pub fn cCopy(self: ZeroingData) std.mem.Allocator.Error!*c_common.pp_zd {
        return c_common.pp_zd_make_copy(self.cPtr());
    }

    pub fn zero(self: *ZeroingData) void {
        c_common.pp_zd_zero(self.cPtr());
        self.refresh();
    }

    pub fn resize(self: *ZeroingData, count: usize) void {
        c_common.pp_zd_resize(self.cPtr(), count);
        self.refresh();
    }

    pub fn append(
        self: *ZeroingData,
        _: std.mem.Allocator,
        suffix: []const u8,
    ) std.mem.Allocator.Error!void {
        const other = c_common.pp_zd_create_from_data(suffix.ptr, suffix.len);
        defer c_common.pp_zd_free(other);
        c_common.pp_zd_append(self.cPtr(), other);
        self.refresh();
    }

    pub fn appendData(self: *ZeroingData, other: ZeroingData) void {
        c_common.pp_zd_append(self.cPtr(), other.cPtr());
        self.refresh();
    }

    pub fn appendByte(
        self: *ZeroingData,
        allocator: std.mem.Allocator,
        byte: u8,
    ) std.mem.Allocator.Error!void {
        const one = [1]u8{byte};
        try self.append(allocator, &one);
    }

    pub fn sliceCopy(
        self: ZeroingData,
        _: std.mem.Allocator,
        offset: usize,
        count: usize,
    ) (std.mem.Allocator.Error || errors.ZeroingDataError)!ZeroingData {
        const slice = c_common.pp_zd_make_slice(self.cPtr(), offset, count) orelse return error.OutOfBounds;
        return fromC(slice);
    }

    pub fn eql(self: ZeroingData, other: []const u8) bool {
        return c_common.pp_zd_equals_to_data(self.cPtr(), other.ptr, other.len);
    }

    pub fn networkU16(self: ZeroingData, offset: usize) errors.ZeroingDataError!u16 {
        if (offset > self.bytes.len or self.bytes.len - offset < 2) return error.OutOfBounds;
        return std.mem.readInt(u16, self.bytes[offset..][0..2], .big);
    }

    pub fn nullTerminatedString(self: ZeroingData, offset: usize) ?[]const u8 {
        if (offset > self.bytes.len) return null;
        const tail = self.bytes[offset..];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse return null;
        return tail[0..end];
    }

    pub fn removePrefix(
        self: *ZeroingData,
        _: std.mem.Allocator,
        count: usize,
    ) (std.mem.Allocator.Error || errors.ZeroingDataError)!void {
        if (count > self.bytes.len) return error.OutOfBounds;
        c_common.pp_zd_remove_until(self.cPtr(), count);
        self.refresh();
    }

    fn refresh(self: *ZeroingData) void {
        const ptr = self.cPtr();
        self.bytes = ptr.*.bytes[0..ptr.*.length];
    }
};

test "ZeroingData delegates append and slice to pp_zd" {
    const allocator = std.testing.allocator;
    var data = try ZeroingData.initCopy(allocator, "abc");
    defer data.deinit(allocator);
    try data.append(allocator, "def");
    try std.testing.expectEqualStrings("abcdef", data.bytes);

    var part = try data.sliceCopy(allocator, 2, 3);
    defer part.deinit(allocator);
    try std.testing.expectEqualStrings("cde", part.bytes);
}
