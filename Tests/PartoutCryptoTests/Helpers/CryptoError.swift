// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCrypto_C

enum PPCryptoError: Error {
    case creation

    case openssl(pp_crypto_error_code)

    init(_ code: pp_crypto_error_code? = nil) {
        guard let code else {
            self = .creation
            return
        }
        self = .openssl(code)
    }
}
