// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

struct PeerConfiguration: Sendable {
    var publicKey: PublicKey
    var preSharedKey: PreSharedKey?
    var allowedIPs = [IPAddressRange]()
    var endpoint: WireGuardEndpoint?
    var persistentKeepAlive: UInt16?
    var rxBytes: UInt64?
    var txBytes: UInt64?
    var lastHandshakeTime: Date?

    init(publicKey: PublicKey) {
        self.publicKey = publicKey
    }
}

extension PeerConfiguration: Equatable {
    static func == (lhs: PeerConfiguration, rhs: PeerConfiguration) -> Bool {
        return lhs.publicKey == rhs.publicKey &&
            lhs.preSharedKey == rhs.preSharedKey &&
            Set(lhs.allowedIPs) == Set(rhs.allowedIPs) &&
            lhs.endpoint == rhs.endpoint &&
            lhs.persistentKeepAlive == rhs.persistentKeepAlive
    }
}

extension PeerConfiguration: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(preSharedKey)
        hasher.combine(Set(allowedIPs))
        hasher.combine(endpoint)
        hasher.combine(persistentKeepAlive)

    }
}
