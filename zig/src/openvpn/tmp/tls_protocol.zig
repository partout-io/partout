// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

/// Owning, type-erased TLS engine interface.
///
/// Buffers returned by the pull methods and `caMD5` belong to the caller and
/// must be released with the allocator passed to the method.
pub const TLSProtocol = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque) anyerror!void,
        is_connected: *const fn (*anyopaque) bool,
        put_plain_text: *const fn (*anyopaque, []const u8) anyerror!void,
        put_raw_plain_text: *const fn (*anyopaque, []const u8) anyerror!void,
        put_cipher_text: *const fn (*anyopaque, []const u8) anyerror!void,
        pull_plain_text: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        pull_cipher_text: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        ca_md5: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn start(self: TLSProtocol) anyerror!void {
        return self.vtable.start(self.ptr);
    }

    pub fn isConnected(self: TLSProtocol) bool {
        return self.vtable.is_connected(self.ptr);
    }

    pub fn putPlainText(self: TLSProtocol, text: []const u8) anyerror!void {
        return self.vtable.put_plain_text(self.ptr, text);
    }

    pub fn putRawPlainText(self: TLSProtocol, text: []const u8) anyerror!void {
        return self.vtable.put_raw_plain_text(self.ptr, text);
    }

    pub fn putCipherText(self: TLSProtocol, data: []const u8) anyerror!void {
        return self.vtable.put_cipher_text(self.ptr, data);
    }

    pub fn pullPlainText(self: TLSProtocol, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.pull_plain_text(self.ptr, allocator);
    }

    pub fn pullCipherText(self: TLSProtocol, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.pull_cipher_text(self.ptr, allocator);
    }

    pub fn caMD5(self: TLSProtocol, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.ca_md5(self.ptr, allocator);
    }

    pub fn deinit(self: *TLSProtocol) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};
