// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutVendorsCryptoCore_C

enum CryptoError: Error {
    case creation

    case openssl(crypto_error_code)

    init(_ code: crypto_error_code? = nil) {
        guard let code else {
            self = .creation
            return
        }
        self = .openssl(code)
    }
}
