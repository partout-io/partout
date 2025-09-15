// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Endpoint {
    init?(wg: WireGuardEndpoint) {
        guard let address = Address(rawValue: wg.host.debugDescription) else {
            return nil
        }
        self.init(address, wg.port.rawValue)
    }

    func toWireGuardEndpoint() throws -> WireGuardEndpoint {
        let wgAddress: String
        switch address {
        case .ip(let raw, let family):
            wgAddress = family == .v6 ? "[\(raw)]" : raw
        case .hostname(let raw):
            wgAddress = raw
        }
        guard let wg = WireGuardEndpoint(from: "\(wgAddress):\(port)") else {
            throw PartoutError(.parsing)
        }
        return wg
    }
}

extension WireGuardEndpoint {
    var toEndpoint: Endpoint? {
        .init(wg: self)
    }
}
