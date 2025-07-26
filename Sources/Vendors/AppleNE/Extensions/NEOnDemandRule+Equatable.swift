// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension

extension NEOnDemandRule {
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else {
            return false
        }
        return equalitySubject == other.equalitySubject
    }
}

private extension NEOnDemandRule {
    var equalitySubject: [[String]] {
        [
            ["\(interfaceTypeMatch.rawValue)"],
            ssidMatch ?? [],
            dnsSearchDomainMatch ?? [],
            dnsServerAddressMatch ?? []
        ]
    }
}
