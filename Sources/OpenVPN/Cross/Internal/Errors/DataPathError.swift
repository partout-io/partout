// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C

enum DataPathError: Error {
    case creation

    case algorithm

    case overflow
}

struct CDataPathError: Error {
    let code: dp_error_code

    static func error(for err: dp_error_t) -> Error {
        if err.dp_code == DataPathErrorCrypto {
            return CCryptoError(err.pp_crypto_code)
        } else {
            return CDataPathError(err.dp_code)
        }
    }

    private init(_ code: dp_error_code) {
        precondition(code != DataPathErrorNone)
        self.code = code
    }
}
