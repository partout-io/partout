// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const c = @import("source").c_crypto;

const has_openssl = @hasDecl(c, "PARTOUT_CRYPTO_OPENSSL");
const has_mbedtls = @hasDecl(c, "PARTOUT_CRYPTO_MBEDTLS");
const backend_count: usize =
    @intFromBool(has_openssl) + 2 * @as(usize, @intFromBool(has_mbedtls));

pub const Backend = struct {
    kind: enum {
        openssl,
        mbedtls,
        native,
    },
    functions: c.pp_crypto_fnt,

    pub fn name(self: Backend) []const u8 {
        return @tagName(self.kind);
    }
};

pub fn backends() [backend_count]Backend {
    var result: [backend_count]Backend = undefined;
    var index: usize = 0;
    if (has_openssl) {
        result[index] = .{
            .kind = .openssl,
            .functions = c.pp_crypto_fnt_openssl(),
        };
        index += 1;
    }
    if (has_mbedtls) {
        result[index] = .{
            .kind = .mbedtls,
            .functions = c.pp_crypto_fnt_mbedtls(),
        };
        index += 1;
        result[index] = .{
            .kind = .native,
            .functions = c.pp_crypto_fnt_native(),
        };
    }
    return result;
}

pub fn hex(comptime encoded: []const u8) [encoded.len / 2]u8 {
    var decoded: [encoded.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, encoded) catch unreachable;
    return decoded;
}

pub fn zeroingData(bytes: []u8) c.pp_zd {
    return .{
        .bytes = bytes.ptr,
        .length = bytes.len,
    };
}

pub fn flags(iv: []const u8, ad: []const u8) c.pp_crypto_flags {
    return .{
        .iv = if (iv.len > 0) iv.ptr else null,
        .iv_len = iv.len,
        .ad = if (ad.len > 0) ad.ptr else null,
        .ad_len = ad.len,
        .for_testing = 1,
    };
}

pub fn encrypt(
    context: c.pp_crypto_ctx,
    input: []const u8,
    crypto_flags: *const c.pp_crypto_flags,
    output: []u8,
) ![]u8 {
    var code: c.pp_crypto_error_code = c.PPCryptoErrorNone;
    const count = c.pp_crypto_encrypt(
        context,
        output.ptr,
        output.len,
        input.ptr,
        input.len,
        crypto_flags,
        &code,
    );
    if (count == 0) return error.EncryptionFailed;
    try std.testing.expectEqual(
        @as(c.pp_crypto_error_code, c.PPCryptoErrorNone),
        code,
    );
    return output[0..count];
}

pub fn decrypt(
    context: c.pp_crypto_ctx,
    input: []const u8,
    crypto_flags: *const c.pp_crypto_flags,
    output: []u8,
) ![]u8 {
    var code: c.pp_crypto_error_code = c.PPCryptoErrorNone;
    const count = c.pp_crypto_decrypt(
        context,
        output.ptr,
        output.len,
        input.ptr,
        input.len,
        crypto_flags,
        &code,
    );
    if (count == 0) return error.DecryptionFailed;
    try std.testing.expectEqual(
        @as(c.pp_crypto_error_code, c.PPCryptoErrorNone),
        code,
    );
    return output[0..count];
}

pub fn verify(context: c.pp_crypto_ctx, input: []const u8) !void {
    var code: c.pp_crypto_error_code = c.PPCryptoErrorNone;
    if (!c.pp_crypto_verify(context, input.ptr, input.len, &code)) {
        return error.VerificationFailed;
    }
    try std.testing.expectEqual(
        @as(c.pp_crypto_error_code, c.PPCryptoErrorNone),
        code,
    );
}

pub fn reportFailure(backend: Backend) void {
    std.debug.print("crypto backend: {s}\n", .{backend.name()});
}
