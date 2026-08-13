// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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

extension NEIPv4Route {
    public func cloned() -> NEIPv4Route {
        let copy = NEIPv4Route(
            destinationAddress: destinationAddress,
            subnetMask: destinationSubnetMask
        )
        copy.gatewayAddress = gatewayAddress
        return copy
    }

    public func hasSameDestination(as other: NEIPv4Route) -> Bool {
        destinationAddress == other.destinationAddress &&
            destinationSubnetMask == other.destinationSubnetMask
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
