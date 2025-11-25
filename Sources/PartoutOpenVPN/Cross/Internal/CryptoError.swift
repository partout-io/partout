// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

enum PPCryptoError: Error {
    case creation

    case hmac
}

struct CCryptoError: Error {
    let code: pp_crypto_error_code

    init(_ code: pp_crypto_error_code) {
        precondition(code != PPCryptoErrorNone)
        self.code = code
    }
}
