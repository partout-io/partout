// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");

pub const common = @cImport({
    @cInclude("c/android_import_compat.h");
    @cInclude("portable/common.h");
    @cInclude("portable/lib.h");
    @cInclude("portable/prng.h");
    @cInclude("portable/zd.h");
});

pub const io = @cImport({
    @cInclude("c/android_import_compat.h");
    @cInclude("portable/mux.h");
    @cInclude("portable/socket.h");
    @cInclude("portable/tun.h");
});

pub const crypto = @cImport({
    @cInclude("c/android_import_compat.h");
    @cInclude("crypto/crypto.h");
});

pub const has_default_crypto_backend = builtin.is_test or
    @hasDecl(crypto, "PARTOUT_CRYPTO_OPENSSL") or
    @hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS");

pub const CryptoBackend = enum {
    openssl,
    mbedtls,
    native,
    mock,

    pub fn default() CryptoBackend {
        if (@hasDecl(crypto, "PARTOUT_CRYPTO_OPENSSL")) return .openssl;
        if (@hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS")) return .native;
        if (builtin.is_test) return .mock;
        @compileError("no default crypto backend is available");
    }
};

pub const CryptoFunctionTableError = error{UnsupportedCryptoBackend};

pub fn cryptoFunctionTable(backend: CryptoBackend) CryptoFunctionTableError!crypto.pp_crypto_fnt {
    return switch (backend) {
        .openssl => if (@hasDecl(crypto, "PARTOUT_CRYPTO_OPENSSL"))
            crypto.pp_crypto_fnt_openssl()
        else
            error.UnsupportedCryptoBackend,
        .mbedtls => if (@hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS"))
            crypto.pp_crypto_fnt_mbedtls()
        else
            error.UnsupportedCryptoBackend,
        .native => if (@hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS"))
            crypto.pp_crypto_fnt_native()
        else
            error.UnsupportedCryptoBackend,
        .mock => if (builtin.is_test)
            crypto.pp_crypto_fnt_mock()
        else
            error.UnsupportedCryptoBackend,
    };
}
