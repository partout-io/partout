// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutVendorsCryptoCore_C

enum CryptoError: Error {
    case creation

    case hmac
}

struct CCryptoError: Error {
    let code: crypto_error_code

    init(_ code: crypto_error_code) {
        precondition(code != CryptoErrorNone)
        self.code = code
    }
}
