// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

final class TLSWrapper {
    struct Parameters: Sendable {
        let cachesURL: URL

        let cfg: OpenVPN.Configuration

        let onVerificationFailure: @Sendable () -> Void
    }

    let tls: TLSProtocol

    init(tls: TLSProtocol) {
        self.tls = tls
    }
}
