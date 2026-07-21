// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const CryptoKeyPair = @import("crypto_key_pair.zig").CryptoKeyPair;

/// Key material for the OpenVPN data channel.
///
/// The value owns every present key pair. Use `move` rather than copying an
/// owning value.
pub const CryptoKeys = struct {
    pub const KeyPair = CryptoKeyPair;
    pub const PRF = @import("crypto_keys_prf.zig").CryptoKeysPRF;

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
