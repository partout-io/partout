// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");

const api = core_mod.api;
const c_common = c_exports_mod.common;
const c_crypto = c_exports_mod.crypto;

pub fn cryptoError(code: c_crypto.pp_crypto_error_code) error{CryptoFailure} {
    std.debug.assert(code != c_crypto.PPCryptoErrorNone);
    return error.CryptoFailure;
}

pub const CryptoBackend = enum {
    openssl,
    mbedtls,
    native,
    mock,
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

    pub fn deinit(self: *CryptoKeyPair, allocator: std.mem.Allocator) void {
        self.encryption_key.deinit(allocator);
        self.decryption_key.deinit(allocator);
        self.* = undefined;
    }

    pub fn move(self: *const CryptoKeyPair) CryptoKeyPair {
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

pub const PIAHardReset = struct {
    pub const obfuscation_key_length: usize = 3;
    pub const magic = "53eo0rk92gxic98p1asgl5auh59r1vp4lmry1e3chzi100qntd";

    ca_md5_digest: []const u8,
    cipher: api.OpenVPNCipher,
    digest: api.OpenVPNDigest,

    pub fn init(
        ca_md5_digest: []const u8,
        cipher: api.OpenVPNCipher,
        digest: api.OpenVPNDigest,
    ) PIAHardReset {
        return .{
            .ca_md5_digest = ca_md5_digest,
            .cipher = cipher,
            .digest = digest,
        };
    }

    /// Returns the PIA-specific encoded hard-reset payload. Caller owns it.
    pub fn encodedData(
        self: PIAHardReset,
        allocator: std.mem.Allocator,
        prng: PRNG,
    ) ![]u8 {
        if (!isASCII(self.ca_md5_digest)) return error.Assertion;

        const cipher_name = try lowerAlloc(allocator, self.cipher.raw());
        defer allocator.free(cipher_name);
        const digest_name = try lowerAlloc(allocator, self.digest.raw());
        defer allocator.free(digest_name);
        const plain = try std.fmt.allocPrint(
            allocator,
            "{s}crypto\t{s}|{s}\tca\t{s}",
            .{ magic, cipher_name, digest_name, self.ca_md5_digest },
        );
        defer allocator.free(plain);

        const result = try allocator.alloc(u8, obfuscation_key_length + plain.len);
        errdefer allocator.free(result);
        try prng.fill(result[0..obfuscation_key_length]);
        for (plain, 0..) |byte, index| {
            result[obfuscation_key_length + index] =
                byte ^ result[index % obfuscation_key_length];
        }
        return result;
    }

    fn lowerAlloc(
        allocator: std.mem.Allocator,
        value: []const u8,
    ) ![]u8 {
        const result = try allocator.alloc(u8, value.len);
        for (value, result) |source, *destination|
            destination.* = std.ascii.toLower(source);
        return result;
    }

    fn isASCII(value: []const u8) bool {
        for (value) |byte| if (!std.ascii.isAscii(byte)) return false;
        return true;
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

    pub fn fromC(ptr: *c_common.pp_zd) ZeroingData {
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

    pub fn cPtr(self: ZeroingData) *c_common.pp_zd {
        return self.ptr orelse @panic("use of deinitialized ZeroingData");
    }

    pub fn cCopy(self: ZeroingData) !*c_common.pp_zd {
        return c_common.pp_zd_make_copy(self.cPtr());
    }

    pub fn zero(self: *ZeroingData) void {
        c_common.pp_zd_zero(self.cPtr());
        self.refresh();
    }

    pub fn resize(self: *const ZeroingData, count: usize) void {
        c_common.pp_zd_resize(self.cPtr(), count);
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

pub fn authKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) !CryptoKeys {
    const bytes = try decodeStaticKey(allocator, key);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const send_index: usize = switch (key.dir orelse .server) {
        .server => 1,
        .client => 3,
    };
    const receive_index: usize = switch (key.dir orelse .client) {
        .server => 3,
        .client => 1,
    };
    var send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, send_index));
    errdefer send.deinit(allocator);
    const receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, receive_index));
    return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
}

pub fn cryptKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) !CryptoKeys {
    const direction = key.dir orelse return error.MissingStaticKeyDirection;
    const bytes = try decodeStaticKey(allocator, key);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const cipher_send_index: usize = if (direction == .server) 0 else 2;
    const cipher_receive_index: usize = if (direction == .server) 2 else 0;
    const hmac_send_index: usize = if (direction == .server) 1 else 3;
    const hmac_receive_index: usize = if (direction == .server) 3 else 1;

    var cipher_send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, cipher_send_index));
    errdefer cipher_send.deinit(allocator);
    var cipher_receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, cipher_receive_index));
    errdefer cipher_receive.deinit(allocator);
    var hmac_send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, hmac_send_index));
    errdefer hmac_send.deinit(allocator);
    const hmac_receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, hmac_receive_index));
    return CryptoKeys.init(
        CryptoKeyPair.init(cipher_send, cipher_receive),
        CryptoKeyPair.init(hmac_send, hmac_receive),
    );
}

const static_key_content_length = 256;
const static_key_length = 64;

fn decodeStaticKey(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) ![]u8 {
    const bytes = try key.data.bytesAlloc(allocator);
    errdefer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    if (bytes.len != static_key_content_length) return error.InvalidStaticKey;
    return bytes;
}

fn staticKeyQuadrant(bytes: []const u8, index: usize) []const u8 {
    return bytes[index * static_key_length .. (index + 1) * static_key_length];
}
