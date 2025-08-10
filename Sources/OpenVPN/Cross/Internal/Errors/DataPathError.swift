// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C

enum OpenVPNDataPathError: Error {
    case creation

    case algorithm

    case overflow
}

struct CDataPathError: Error {
    let code: openvpn_dp_error_code

    static func error(for err: openvpn_dp_error) -> Error {
        if err.dp_code == OpenVPNDataPathErrorCrypto {
            return CCryptoError(err.crypto_code)
        } else {
            return CDataPathError(err.dp_code)
        }
    }

    private init(_ code: openvpn_dp_error_code) {
        precondition(code != OpenVPNDataPathErrorNone)
        self.code = code
    }
}
