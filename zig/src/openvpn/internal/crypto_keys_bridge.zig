// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_common = @import("../../c/exports.zig").common;
const c_crypto = @import("../../c/exports.zig").crypto;
const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

/// Owns the C copies backing a `pp_crypto_keys` value.
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
