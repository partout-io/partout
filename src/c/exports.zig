// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const std = @import("std");

pub const portable = @import("portable_c");
pub const io = @import("io_c");
pub const crypto = @import("crypto_c");

pub const has_default_crypto_backend = builtin.is_test or
    @hasDecl(crypto, "PARTOUT_CRYPTO_OPENSSL") or
    @hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS");

pub const CryptoError = error{ CryptoEncryption, CryptoHMAC };

pub fn errorForCryptoErrorCode(code: crypto.pp_crypto_error_code) CryptoError {
    std.debug.assert(code != crypto.PPCryptoErrorNone);
    return switch (code) {
        crypto.PPCryptoErrorEncryption => error.CryptoEncryption,
        crypto.PPCryptoErrorHMAC => error.CryptoHMAC,
        else => error.CryptoEncryption,
    };
}
