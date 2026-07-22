// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_common = @import("../../c/exports.zig").common;
const c_crypto = @import("../../c/exports.zig").crypto;
const CryptoBackend = @import("crypto_backend.zig").CryptoBackend;

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
