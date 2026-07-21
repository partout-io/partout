// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const c = @import("c.zig").api;

/// Runtime crypto backend selection used by the Swift API.
pub const CryptoBackend = enum {
    open_ssl,
    mbed_tls,
    native,
    mock,

    pub fn functionTable(self: CryptoBackend) c.pp_crypto_fnt {
        return switch (self) {
            .open_ssl => c.pp_crypto_fnt_openssl(),
            .mbed_tls => c.pp_crypto_fnt_mbedtls(),
            .native => c.pp_crypto_fnt_native(),
            .mock => c.pp_crypto_fnt_mock(),
        };
    }
};
