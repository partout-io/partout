// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const c_crypto = @import("../../c/exports.zig").crypto;

/// Runtime crypto backend selection used by the Swift API.
pub const CryptoBackend = enum {
    open_ssl,
    mbed_tls,
    native,
    mock,

    pub fn functionTable(self: CryptoBackend) c_crypto.pp_crypto_fnt {
        return switch (self) {
            .open_ssl => c_crypto.pp_crypto_fnt_openssl(),
            .mbed_tls => c_crypto.pp_crypto_fnt_mbedtls(),
            .native => c_crypto.pp_crypto_fnt_native(),
            .mock => c_crypto.pp_crypto_fnt_mock(),
        };
    }
};
