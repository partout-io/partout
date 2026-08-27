// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

extension CryptoBackend {
    static var `default`: Self {
#if PARTOUT_CRYPTO_OPENSSL
        .openssl
#elseif PARTOUT_CRYPTO_MBEDTLS
        .native
#else
        fatalError("No crypto backend available")
#endif
    }

    var functionTable: pp_crypto_fnt {
        switch self {
#if PARTOUT_CRYPTO_OPENSSL
        case .openssl: pp_crypto_fnt_openssl()
#endif
#if PARTOUT_CRYPTO_MBEDTLS
        case .mbedtls: pp_crypto_fnt_mbedtls()
        case .native: pp_crypto_fnt_native()
#endif
        case .mock: fatalError("Mock crypto table?")
        default: fatalError("Unknown crypto backend: \(self)")
        }
    }
}
