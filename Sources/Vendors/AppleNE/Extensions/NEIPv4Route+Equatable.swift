// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension

extension NEIPv4Route {
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else {
            return false
        }
        return equalitySubject == other.equalitySubject
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(equalitySubject)
        return hasher.finalize()
    }

    open override var debugDescription: String {
        "\(destinationAddress)/\(destinationSubnetMask) -> \(gatewayAddress ?? "*")"
    }
}

private extension NEIPv4Route {
    var equalitySubject: [String?] {
        [
            destinationAddress,
            destinationSubnetMask,
            gatewayAddress
        ]
    }
}
