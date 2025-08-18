// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutOpenVPN
#endif

extension Notification.Name {
    static let tlsDidFailVerificationNotification = Notification.Name("TLSDidFailVerificationNotification")
}

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
