// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NEIPv6Settings {
    open override var debugDescription: String {
        precondition(addresses.count == networkPrefixLengths.count)
        let subnets = addresses.enumerated().reduce(into: []) {
            $0.append("\($1.element)/\(networkPrefixLengths[$1.offset])")
        }
        return "\(subnets), included=\(includedRoutes ?? []), excluded=\(excludedRoutes ?? [])"
    }
}
