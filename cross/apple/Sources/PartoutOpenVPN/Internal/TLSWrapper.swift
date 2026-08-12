// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

final class TLSWrapper {
    struct Parameters: Sendable {
        let fnt: pp_crypto_tls_fnt
        let cachesURL: URL
        let cfg: OpenVPN.Configuration
        let onVerificationFailure: @Sendable () -> Void
    }

    let tls: TLSProtocol

    init(tls: TLSProtocol) {
        self.tls = tls
    }
}
