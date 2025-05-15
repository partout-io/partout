//
//  OnDemandModule+NE.swift
//  Partout
//
//  Created by Davide De Rosa on 3/14/22.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NetworkExtension
import PartoutCore

extension OnDemandModule {
    func neRules(_ ctx: PartoutContext) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []

        // apply exceptions (unless .any)
        if policy != .any {
            if Self.supportsCellular, withMobileNetwork {
                if let rule = cellularRule() {
                    rules.append(rule)
                } else {
                    pp_log(ctx, .ne, .info, "Not adding rule for NEOnDemandRuleInterfaceType.cellular (not compatible)")
                }
            }
            if Self.supportsEthernet, withEthernetNetwork {
                if let rule = ethernetRule() {
                    rules.append(rule)
                } else {
                    pp_log(ctx, .ne, .info, "Not adding rule for NEOnDemandRuleInterfaceType.ethernet (not compatible)")
                }
            }
            let SSIDs = Array(withSSIDs.filter { $1 }.keys)
            if !SSIDs.isEmpty {
                rules.append(wifiRule(SSIDs: SSIDs))
            }
        }

        // IMPORTANT: append fallback rule last
        rules.append(globalRule())

        pp_log(ctx, .ne, .info, "On-demand rules:")
        rules.forEach {
            pp_log(ctx, .ne, .info, "\($0)")
        }

        return rules
    }
}

private extension OnDemandModule {
    func globalRule() -> NEOnDemandRule {
        let rule: NEOnDemandRule
        switch policy {
        case .any, .excluding:
            rule = NEOnDemandRuleConnect()
        case .including:
            rule = NEOnDemandRuleIgnore()
        @unknown default:
            rule = NEOnDemandRuleConnect()
        }
        rule.interfaceTypeMatch = .any
        return rule
    }

    func networkRule(matchingInterface interfaceType: NEOnDemandRuleInterfaceType) -> NEOnDemandRule {
        let rule: NEOnDemandRule
        switch policy {
        case .any, .excluding:
            rule = NEOnDemandRuleDisconnect()
        case .including:
            rule = NEOnDemandRuleConnect()
        @unknown default:
            rule = NEOnDemandRuleDisconnect()
        }
        rule.interfaceTypeMatch = interfaceType
        return rule
    }

    func cellularRule() -> NEOnDemandRule? {
#if os(iOS)
        networkRule(matchingInterface: .cellular)
#else
        nil
#endif
    }

    func ethernetRule() -> NEOnDemandRule? {
#if os(macOS) || os(tvOS)
        networkRule(matchingInterface: .ethernet)
#else
        nil
#endif
    }

    func wifiRule(SSIDs: [String]) -> NEOnDemandRule {
        let rule = networkRule(matchingInterface: .wiFi)
        rule.ssidMatch = SSIDs.sorted() // for testing
        return rule
    }
}
