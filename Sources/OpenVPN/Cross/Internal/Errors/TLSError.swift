// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
internal import _PartoutVendorsTLSCore_C

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
