// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

public enum CryptoBackend: Sendable {
#if PARTOUT_CRYPTO_OPENSSL
    case openSSL
#endif
#if PARTOUT_CRYPTO_MBEDTLS
    case mbedTLS
    case native
#endif
}

extension CryptoBackend {
    static var `default`: Self {
#if PARTOUT_CRYPTO_OPENSSL
        .openSSL
#elseif PARTOUT_CRYPTO_MBEDTLS
        .native
#else
        fatalError("No crypto backend available")
#endif
    }

    var functionTable: pp_crypto_fnt {
        switch self {
#if PARTOUT_CRYPTO_OPENSSL
        case .openSSL: pp_crypto_fnt_openssl()
#endif
#if PARTOUT_CRYPTO_MBEDTLS
        case .mbedTLS: pp_crypto_fnt_mbedtls()
        case .native: pp_crypto_fnt_native()
#endif
        }
    }
}
