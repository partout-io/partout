// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension OnDemandModule {
    func neRules(_ ctx: PartoutLoggerContext) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []

        // apply exceptions (unless .any)
        if policy != .any {
            if Self.supportsCellular, withMobileNetwork {
                if let rule = cellularRule() {
                    rules.append(rule)
                } else {
                    pp_log(ctx, .os, .info, "Not adding rule for NEOnDemandRuleInterfaceType.cellular (not compatible)")
                }
            }
            if Self.supportsEthernet, withEthernetNetwork {
                if let rule = ethernetRule() {
                    rules.append(rule)
                } else {
                    pp_log(ctx, .os, .info, "Not adding rule for NEOnDemandRuleInterfaceType.ethernet (not compatible)")
                }
            }
            let SSIDs = Array(withSSIDs.filter { $1 }.keys)
            if !SSIDs.isEmpty {
                rules.append(wifiRule(SSIDs: SSIDs))
            }
        }

        // IMPORTANT: append fallback rule last
        rules.append(globalRule())

        pp_log(ctx, .os, .info, "On-demand rules:")
        rules.forEach {
            pp_log(ctx, .os, .info, "\($0)")
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
