// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");

pub const common = @cImport({
    @cInclude("portable/common.h");
    @cInclude("portable/lib.h");
    @cInclude("portable/prng.h");
    @cInclude("portable/zd.h");
});

pub const io = @cImport({
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

pub fn cryptoFunctionTable(backend: CryptoBackend) crypto.pp_crypto_fnt {
    return switch (backend) {
        .openssl => if (@hasDecl(crypto, "PARTOUT_CRYPTO_OPENSSL"))
            crypto.pp_crypto_fnt_openssl()
        else
            unreachable,
        .mbedtls => if (@hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS"))
            crypto.pp_crypto_fnt_mbedtls()
        else
            unreachable,
        .native => if (@hasDecl(crypto, "PARTOUT_CRYPTO_MBEDTLS"))
            crypto.pp_crypto_fnt_native()
        else
            unreachable,
        .mock => if (builtin.is_test)
            crypto.pp_crypto_fnt_mock()
        else
            unreachable,
    };
}
