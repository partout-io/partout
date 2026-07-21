// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

/// One OpenVPN encryption/decryption key pair.
///
/// The value owns both buffers. Use `move` when transferring it.
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
