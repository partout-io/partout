// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports = @import("../../c/exports.zig");
const c_common = c_exports.common;
const c_crypto = c_exports.crypto;
const errors = @import("errors.zig");

pub const CryptoBackend = enum {
    open_ssl,
    mbed_tls,
    native,
    mock,

    pub fn functionTable(self: CryptoBackend) c_crypto.pp_crypto_fnt {
        return switch (self) {
            .open_ssl => c_crypto.pp_crypto_fnt_openssl(),
            .mbed_tls => c_crypto.pp_crypto_fnt_mbedtls(),
            .native => c_crypto.pp_crypto_fnt_native(),
            .mock => c_crypto.pp_crypto_fnt_mock(),
        };
    }
};

pub const CryptoKeyPair = struct {
    encryption_key: ZeroingData,
    decryption_key: ZeroingData,

    pub fn init(encryption_key: ZeroingData, decryption_key: ZeroingData) CryptoKeyPair {
        return .{
            .encryption_key = encryption_key,
            .decryption_key = decryption_key,
        };
    }

    pub fn initEmpty(
        allocator: std.mem.Allocator,
        length: usize,
    ) std.mem.Allocator.Error!CryptoKeyPair {
        var encryption_key = try ZeroingData.init(allocator, length);
        errdefer encryption_key.deinit(allocator);
        const decryption_key = try ZeroingData.init(allocator, length);
        return init(encryption_key, decryption_key);
    }

    pub fn clone(
        self: CryptoKeyPair,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!CryptoKeyPair {
        var encryption_key = try self.encryption_key.clone(allocator);
        errdefer encryption_key.deinit(allocator);
        const decryption_key = try self.decryption_key.clone(allocator);
        return init(encryption_key, decryption_key);
    }

    pub fn deinit(self: *CryptoKeyPair, allocator: std.mem.Allocator) void {
        self.encryption_key.deinit(allocator);
        self.decryption_key.deinit(allocator);
        self.* = undefined;
    }

    pub fn move(self: *CryptoKeyPair) CryptoKeyPair {
        return .{
            .encryption_key = self.encryption_key.move(),
            .decryption_key = self.decryption_key.move(),
        };
    }
};

pub const CryptoKeys = struct {
    pub const KeyPair = CryptoKeyPair;

    cipher: ?CryptoKeyPair = null,
    digest: ?CryptoKeyPair = null,

    pub fn init(cipher: ?CryptoKeyPair, digest: ?CryptoKeyPair) CryptoKeys {
        return .{ .cipher = cipher, .digest = digest };
    }

    pub fn initEmpty(
        allocator: std.mem.Allocator,
        cipher_key_length: usize,
        hmac_key_length: usize,
    ) std.mem.Allocator.Error!CryptoKeys {
        var cipher = try CryptoKeyPair.initEmpty(allocator, cipher_key_length);
        errdefer cipher.deinit(allocator);
        const digest = try CryptoKeyPair.initEmpty(allocator, hmac_key_length);
        return init(cipher, digest);
    }

    pub fn clone(
        self: CryptoKeys,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!CryptoKeys {
        var cipher: ?CryptoKeyPair = if (self.cipher) |value|
            try value.clone(allocator)
        else
            null;
        errdefer if (cipher) |*value| value.deinit(allocator);
        const digest: ?CryptoKeyPair = if (self.digest) |value|
            try value.clone(allocator)
        else
            null;
        return init(cipher, digest);
    }

    pub fn deinit(self: *CryptoKeys, allocator: std.mem.Allocator) void {
        if (self.cipher) |*value| value.deinit(allocator);
        if (self.digest) |*value| value.deinit(allocator);
        self.* = .{};
    }

    pub fn move(self: *CryptoKeys) CryptoKeys {
        var result: CryptoKeys = .{};
        if (self.cipher) |*value| result.cipher = value.move();
        if (self.digest) |*value| result.digest = value.move();
        self.* = .{};
        return result;
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
    ) std.mem.Allocator.Error!CryptoKeysBridge {
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
    ) std.mem.Allocator.Error!*c_common.pp_zd {
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

    pub fn fill(self: PRNG, destination: []u8) errors.PRNGError!void {
        if (!self.fill_fn(self.context, destination)) return error.CryptoFailure;
    }

    pub fn data(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) (std.mem.Allocator.Error || errors.PRNGError)![]u8 {
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try self.fill(bytes);
        return bytes;
    }

    pub fn safeData(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) (std.mem.Allocator.Error || errors.PRNGError)!ZeroingData {
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

pub const SimpleKeyDecrypter = struct {
    fnt: c_crypto.pp_crypto_fnt,

    pub fn init(backend: CryptoBackend) SimpleKeyDecrypter {
        return .{ .fnt = backend.functionTable() };
    }

    /// Caller owns the returned plaintext key.
    pub fn decryptedKeyFromPEM(
        self: SimpleKeyDecrypter,
        allocator: std.mem.Allocator,
        pem: []const u8,
        passphrase: []const u8,
    ) anyerror![]u8 {
        const c_pem = try allocator.dupeZ(u8, pem);
        defer allocator.free(c_pem);
        const c_passphrase = try allocator.dupeZ(u8, passphrase);
        defer allocator.free(c_passphrase);
        const decrypt = self.fnt.key_decrypted_from_pem orelse return error.UnsupportedAlgorithm;
        const value = decrypt(
            c_pem.ptr,
            c_passphrase.ptr,
        ) orelse return error.UnsupportedAlgorithm;
        return copyAndDestroy(allocator, value);
    }

    /// Caller owns the returned plaintext key.
    pub fn decryptedKeyFromPath(
        self: SimpleKeyDecrypter,
        allocator: std.mem.Allocator,
        path: []const u8,
        passphrase: []const u8,
    ) anyerror![]u8 {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);
        const c_passphrase = try allocator.dupeZ(u8, passphrase);
        defer allocator.free(c_passphrase);
        const decrypt = self.fnt.key_decrypted_from_path orelse return error.UnsupportedAlgorithm;
        const value = decrypt(
            c_path.ptr,
            c_passphrase.ptr,
        ) orelse return error.UnsupportedAlgorithm;
        return copyAndDestroy(allocator, value);
    }

    fn copyAndDestroy(
        allocator: std.mem.Allocator,
        value: [*c]u8,
    ) std.mem.Allocator.Error![]u8 {
        const source = std.mem.span(@as([*:0]u8, @ptrCast(value)));
        defer {
            c_common.pp_zero(value, source.len);
            c_common.pp_free(value);
        }
        return allocator.dupe(u8, source);
    }
};

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
