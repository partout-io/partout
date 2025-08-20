// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Network
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension Subnet {
    init?(wg: IPAddressRange) {
        guard let ipAddress = wg.address.rawValue.asIPAddress,
              let address = Address(rawValue: ipAddress) else {
            return nil
        }
        self.init(address, Int(wg.networkPrefixLength))
    }

    func toWireGuardRange() throws -> IPAddressRange {
        guard let wg = IPAddressRange(from: "\(address)/\(prefixLength)") else {
            throw PartoutError(.parsing)
        }
        return wg
    }
}

extension IPAddressRange {
    var toSubnet: Subnet? {
        .init(wg: self)
    }
}
