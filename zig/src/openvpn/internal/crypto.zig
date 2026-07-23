// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");

const c_common = c_exports_mod.common;
const c_crypto = c_exports_mod.crypto;

pub const CryptoKeys = struct {
    pub const KeyPair = struct {
        encryption_key: ZeroingData,
        decryption_key: ZeroingData,

        pub fn init(encryption_key: ZeroingData, decryption_key: ZeroingData) KeyPair {
            return .{
                .encryption_key = encryption_key,
                .decryption_key = decryption_key,
            };
        }

        pub fn deinit(self: *KeyPair, allocator: std.mem.Allocator) void {
            self.encryption_key.deinit(allocator);
            self.decryption_key.deinit(allocator);
            self.* = undefined;
        }
    };

    cipher: ?KeyPair = null,
    digest: ?KeyPair = null,

    pub fn init(cipher: ?KeyPair, digest: ?KeyPair) CryptoKeys {
        return .{ .cipher = cipher, .digest = digest };
    }

    pub fn deinit(self: *CryptoKeys, allocator: std.mem.Allocator) void {
        if (self.cipher) |*value| value.deinit(allocator);
        if (self.digest) |*value| value.deinit(allocator);
        self.* = .{};
    }
};

pub const CryptoKeysBridge = struct {
    cipher_encryption_key: *c_common.pp_zd,
    cipher_decryption_key: *c_common.pp_zd,
    hmac_encryption_key: *c_common.pp_zd,
    hmac_decryption_key: *c_common.pp_zd,
    c_keys: c_crypto.pp_crypto_keys,

    pub fn init(
        allocator: std.mem.Allocator,
        keys: *const CryptoKeys,
    ) !CryptoKeysBridge {
        const cipher_encryption_key = try copyOptional(
            allocator,
            if (keys.cipher) |value| value.encryption_key else null,
        );
        errdefer c_common.pp_zd_free(cipher_encryption_key);
        const cipher_decryption_key = try copyOptional(
            allocator,
            if (keys.cipher) |value| value.decryption_key else null,
        );
        errdefer c_common.pp_zd_free(cipher_decryption_key);
        const hmac_encryption_key = try copyOptional(
            allocator,
            if (keys.digest) |value| value.encryption_key else null,
        );
        errdefer c_common.pp_zd_free(hmac_encryption_key);
        const hmac_decryption_key = try copyOptional(
            allocator,
            if (keys.digest) |value| value.decryption_key else null,
        );
        errdefer c_common.pp_zd_free(hmac_decryption_key);

        return .{
            .cipher_encryption_key = cipher_encryption_key,
            .cipher_decryption_key = cipher_decryption_key,
            .hmac_encryption_key = hmac_encryption_key,
            .hmac_decryption_key = hmac_decryption_key,
            .c_keys = .{
                .cipher = .{
                    .enc_key = @ptrCast(cipher_encryption_key),
                    .dec_key = @ptrCast(cipher_decryption_key),
                },
                .hmac = .{
                    .enc_key = @ptrCast(hmac_encryption_key),
                    .dec_key = @ptrCast(hmac_decryption_key),
                },
            },
        };
    }

    pub fn deinit(self: *CryptoKeysBridge) void {
        c_common.pp_zd_free(self.cipher_encryption_key);
        c_common.pp_zd_free(self.cipher_decryption_key);
        c_common.pp_zd_free(self.hmac_encryption_key);
        c_common.pp_zd_free(self.hmac_decryption_key);
        self.* = undefined;
    }

    /// Borrowed pointer valid while the bridge remains alive and unmoved.
    pub fn native(self: *const CryptoKeysBridge) *const c_crypto.pp_crypto_keys {
        return &self.c_keys;
    }

    fn copyOptional(
        allocator: std.mem.Allocator,
        value: ?ZeroingData,
    ) !*c_common.pp_zd {
        return if (value) |data| try data.cCopy() else blk: {
            _ = allocator;
            break :blk c_common.pp_zd_create(0);
        };
    }
};

pub const PRNG = struct {
    context: ?*anyopaque = null,
    fill_fn: *const fn (?*anyopaque, []u8) bool = systemFill,

    pub fn system() PRNG {
        return .{};
    }

    pub fn fill(self: PRNG, destination: []u8) !void {
        if (!self.fill_fn(self.context, destination)) return error.CryptoFailure;
    }

    pub fn data(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) ![]u8 {
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try self.fill(bytes);
        return bytes;
    }

    pub fn safeData(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) !ZeroingData {
        var result = try ZeroingData.init(allocator, length);
        errdefer result.deinit(allocator);
        try self.fill(result.bytes);
        return result;
    }

    fn systemFill(_: ?*anyopaque, destination: []u8) bool {
        if (destination.len == 0) return true;
        return c_common.pp_prng_do(destination.ptr, destination.len);
    }
};

pub const ZeroingData = struct {
    ptr: ?*c_common.pp_zd = null,
    bytes: []u8 = @constCast(&[_]u8{}),

    pub fn init(_: std.mem.Allocator, count: usize) !ZeroingData {
        return fromC(c_common.pp_zd_create(count));
    }

    pub fn initCopy(
        _: std.mem.Allocator,
        source: []const u8,
    ) !ZeroingData {
        return fromC(c_common.pp_zd_create_from_data(source.ptr, source.len));
    }

    pub fn initString(
        _: std.mem.Allocator,
        source: []const u8,
        null_terminated: bool,
    ) !ZeroingData {
        const length = source.len + @intFromBool(null_terminated);
        var result = fromC(c_common.pp_zd_create(length));
        @memcpy(result.bytes[0..source.len], source);
        if (null_terminated) result.bytes[source.len] = 0;
        return result;
    }

    fn fromC(ptr: *c_common.pp_zd) ZeroingData {
        return .{
            .ptr = ptr,
            .bytes = ptr.*.bytes[0..ptr.*.length],
        };
    }

    pub fn clone(self: ZeroingData, _: std.mem.Allocator) !ZeroingData {
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

    fn cPtr(self: ZeroingData) *c_common.pp_zd {
        return self.ptr orelse @panic("use of deinitialized ZeroingData");
    }

    fn cCopy(self: ZeroingData) !*c_common.pp_zd {
        return c_common.pp_zd_make_copy(self.cPtr());
    }

    pub fn zero(self: *ZeroingData) void {
        c_common.pp_zd_zero(self.cPtr());
        self.refresh();
    }

    pub fn append(
        self: *ZeroingData,
        _: std.mem.Allocator,
        suffix: []const u8,
    ) !void {
        const other = c_common.pp_zd_create_from_data(suffix.ptr, suffix.len);
        defer c_common.pp_zd_free(other);
        c_common.pp_zd_append(self.cPtr(), other);
        self.refresh();
    }

    pub fn appendData(self: *ZeroingData, other: ZeroingData) void {
        c_common.pp_zd_append(self.cPtr(), other.cPtr());
        self.refresh();
    }

    pub fn sliceCopy(
        self: ZeroingData,
        _: std.mem.Allocator,
        offset: usize,
        count: usize,
    ) !ZeroingData {
        const slice = c_common.pp_zd_make_slice(self.cPtr(), offset, count) orelse return error.OutOfBounds;
        return fromC(slice);
    }

    pub fn networkU16(self: ZeroingData, offset: usize) !u16 {
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
    ) !void {
        if (count > self.bytes.len) return error.OutOfBounds;
        c_common.pp_zd_remove_until(self.cPtr(), count);
        self.refresh();
    }

    fn refresh(self: *ZeroingData) void {
        const ptr = self.cPtr();
        self.bytes = ptr.*.bytes[0..ptr.*.length];
    }
};
