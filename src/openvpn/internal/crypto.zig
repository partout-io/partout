// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const ffi = @import("../../c/exports.zig");

const portable_c = ffi.portable;
const crypto_c = ffi.crypto;

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

        pub fn deinit(self: *KeyPair) void {
            self.encryption_key.deinit();
            self.decryption_key.deinit();
        }
    };

    cipher: ?KeyPair = null,
    digest: ?KeyPair = null,

    pub fn init(cipher: ?KeyPair, digest: ?KeyPair) CryptoKeys {
        return .{ .cipher = cipher, .digest = digest };
    }

    pub fn deinit(self: *CryptoKeys) void {
        if (self.cipher) |*value| value.deinit();
        if (self.digest) |*value| value.deinit();
    }
};

pub const CryptoKeysBridge = struct {
    cipher_encryption_key: *portable_c.pp_zd,
    cipher_decryption_key: *portable_c.pp_zd,
    hmac_encryption_key: *portable_c.pp_zd,
    hmac_decryption_key: *portable_c.pp_zd,
    c_keys: crypto_c.pp_crypto_keys,

    pub fn init(keys: *const CryptoKeys) CryptoKeysBridge {
        const cipher_encryption_key = copyOptional(
            if (keys.cipher) |value| value.encryption_key else null,
        );
        const cipher_decryption_key = copyOptional(
            if (keys.cipher) |value| value.decryption_key else null,
        );
        const hmac_encryption_key = copyOptional(
            if (keys.digest) |value| value.encryption_key else null,
        );
        const hmac_decryption_key = copyOptional(
            if (keys.digest) |value| value.decryption_key else null,
        );

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
        portable_c.pp_zd_free(self.cipher_encryption_key);
        portable_c.pp_zd_free(self.cipher_decryption_key);
        portable_c.pp_zd_free(self.hmac_encryption_key);
        portable_c.pp_zd_free(self.hmac_decryption_key);
    }

    /// Borrowed pointer valid while the bridge remains alive and unmoved.
    pub fn native(self: *const CryptoKeysBridge) *const crypto_c.pp_crypto_keys {
        return &self.c_keys;
    }

    fn copyOptional(value: ?ZeroingData) *portable_c.pp_zd {
        return if (value) |data| data.cCopy() else portable_c.pp_zd_create(0);
    }
};

pub const PRNG = PRNGWith(SystemRandom);
pub const PRNGError = std.mem.Allocator.Error || error{CryptoPRNG};

pub fn PRNGWith(comptime Provider: type) type {
    return struct {
        const Self = @This();

        provider: Provider,

        pub fn init(provider: Provider) Self {
            return .{ .provider = provider };
        }

        pub fn system() Self {
            return init(.{});
        }

        pub fn fill(self: Self, destination: []u8) PRNGError!void {
            if (!self.provider.fill(destination)) return error.CryptoPRNG;
        }

        pub fn data(
            self: Self,
            allocator: std.mem.Allocator,
            length: usize,
        ) PRNGError![]u8 {
            const bytes = try allocator.alloc(u8, length);
            errdefer allocator.free(bytes);
            try self.fill(bytes);
            return bytes;
        }

        pub fn safeData(self: Self, length: usize) PRNGError!ZeroingData {
            var result = ZeroingData.init(length);
            errdefer result.deinit();
            try self.fill(result.asMutableSlice());
            return result;
        }
    };
}

const SystemRandom = struct {
    fn fill(_: SystemRandom, destination: []u8) bool {
        if (destination.len == 0) return true;
        return portable_c.pp_prng_do(destination.ptr, destination.len);
    }
};

pub const ZeroingData = struct {
    pub const Error = error{OutOfBounds};

    ptr: *portable_c.pp_zd,

    pub fn init(count: usize) ZeroingData {
        return fromC(portable_c.pp_zd_create(count));
    }

    pub fn initCopy(source: []const u8) ZeroingData {
        return fromC(portable_c.pp_zd_create_from_data(source.ptr, source.len));
    }

    pub fn initString(source: []const u8, null_terminated: bool) ZeroingData {
        const result_length = source.len + @intFromBool(null_terminated);
        var result = init(result_length);
        const result_bytes = result.asMutableSlice();
        @memcpy(result_bytes[0..source.len], source);
        if (null_terminated) result_bytes[source.len] = 0;
        return result;
    }

    fn fromC(ptr: *portable_c.pp_zd) ZeroingData {
        return .{ .ptr = ptr };
    }

    pub fn clone(self: ZeroingData) ZeroingData {
        return fromC(portable_c.pp_zd_make_copy(self.cPtr()));
    }

    pub fn deinit(self: *ZeroingData) void {
        portable_c.pp_zd_free(self.ptr);
    }

    fn cPtr(self: ZeroingData) *portable_c.pp_zd {
        return self.ptr;
    }

    fn cCopy(self: ZeroingData) *portable_c.pp_zd {
        return portable_c.pp_zd_make_copy(self.cPtr());
    }

    /// Borrowed view valid until the next mutation or deinitialization.
    pub fn asSlice(self: ZeroingData) []const u8 {
        return self.bytes()[0..self.length()];
    }

    /// Borrowed mutable view valid until the next mutation or deinitialization.
    pub fn asMutableSlice(self: *ZeroingData) []u8 {
        return self.mutableBytes()[0..self.length()];
    }

    pub fn bytes(self: ZeroingData) [*c]const u8 {
        return portable_c.pp_zd_bytes(self.cPtr());
    }

    pub fn mutableBytes(self: *ZeroingData) [*c]u8 {
        return portable_c.pp_zd_mutable_bytes(self.cPtr());
    }

    pub fn length(self: ZeroingData) usize {
        return portable_c.pp_zd_length(self.cPtr());
    }

    pub fn zero(self: *ZeroingData) void {
        portable_c.pp_zd_zero(self.cPtr());
    }

    pub fn clear(self: *ZeroingData) void {
        portable_c.pp_zd_resize(self.cPtr(), 0);
    }

    pub fn append(self: *ZeroingData, suffix: []const u8) void {
        portable_c.pp_zd_append_data(self.cPtr(), suffix.ptr, suffix.len);
    }

    pub fn appendData(self: *ZeroingData, other: ZeroingData) void {
        portable_c.pp_zd_append(self.cPtr(), other.cPtr());
    }

    pub fn sliceCopy(
        self: ZeroingData,
        offset: usize,
        count: usize,
    ) Error!ZeroingData {
        const total_length = self.length();
        if (offset > total_length or count > total_length - offset) return error.OutOfBounds;
        return fromC(portable_c.pp_zd_make_slice(self.cPtr(), offset, count) orelse unreachable);
    }

    pub fn networkU16(self: ZeroingData, offset: usize) Error!u16 {
        const data = self.asSlice();
        if (offset > data.len or data.len - offset < 2) return error.OutOfBounds;
        return std.mem.readInt(u16, data[offset..][0..2], .big);
    }

    pub fn nullTerminatedString(self: ZeroingData, offset: usize) ?[]const u8 {
        const data = self.asSlice();
        if (offset > data.len) return null;
        const tail = data[offset..];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse return null;
        return tail[0..end];
    }

    pub fn removePrefix(
        self: *ZeroingData,
        count: usize,
    ) Error!void {
        if (count > self.length()) return error.OutOfBounds;
        portable_c.pp_zd_remove_until(self.cPtr(), count);
    }
};
