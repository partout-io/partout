// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const std = @import("std");

pub const portable = @cImport({
    @cInclude("portable/common.h");
    @cInclude("portable/lib.h");
    @cInclude("portable/prng.h");
    @cInclude("portable/zd.h");
});

pub const io = @cImport({
    @cInclude("portable/dns.h");
    @cInclude("portable/mux.h");
    @cInclude("portable/socket.h");
    @cInclude("portable/tun.h");
});

pub const crypto = @cImport({
    @cInclude("crypto/crypto.h");
});

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
