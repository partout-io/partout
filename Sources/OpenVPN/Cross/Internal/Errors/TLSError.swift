// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C

enum TLSError: Error {
    case missingCA

    case start

    case peerVerification

    case noData

    case encryption
}

struct CTLSError: Error {
    let code: tls_error_code

    init(_ code: tls_error_code) {
        precondition(code != TLSErrorNone)
        self.code = code
    }
}
