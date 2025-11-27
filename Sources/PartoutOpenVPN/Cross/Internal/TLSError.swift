// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_implementationOnly import _PartoutOpenVPN_C
@_implementationOnly import _PartoutTLS_C

enum PPTLSError: Error {
    case missingCA

    case start

    case peerVerification

    case noData

    case encryption
}

struct CTLSError: Error {
    let code: pp_tls_error_code

    init(_ code: pp_tls_error_code) {
        precondition(code != PPTLSErrorNone)
        self.code = code
    }
}
