// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NEIPv4Settings {
    open override var debugDescription: String {
        precondition(addresses.count == subnetMasks.count)
        let subnets = addresses.enumerated().reduce(into: []) {
            $0.append("\($1.element)/\(subnetMasks[$1.offset])")
        }
        return "\(subnets), included=\(includedRoutes ?? []), excluded=\(excludedRoutes ?? [])"
    }
}
