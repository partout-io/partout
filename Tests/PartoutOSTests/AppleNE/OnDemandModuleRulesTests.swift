// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
import PartoutCore
@testable import PartoutOS
import Testing

struct OnDemandModuleRulesTests {
    @Test
    func givenAnyPolicy_whenGetRules_thenHasConnect() {
        var module = OnDemandModule.Builder()
        module.policy = .any

        let sut = module.build()

        #expect(sut.neRules == [
            NEOnDemandRuleConnect()
        ])
    }

    @Test
    func givenExcludingPolicy_whenGetRules_thenHasConnect() {
        var module = OnDemandModule.Builder()
        module.policy = .excluding

        let sut = module.build()

        #expect(sut.neRules == [
            NEOnDemandRuleConnect()
        ])
    }

    @Test
    func givenExcludingPolicyWithCustomRules_whenGetRules_thenHasConnectExceptExcludedNetworks() throws {
        var module = OnDemandModule.Builder()
        module.policy = .excluding
        module.withMobileNetwork = true
        module.withEthernetNetwork = true
        module.withSSIDs = [
            "nope": true,
            "home": true,
            "yep": false
        ]

        let sut = module.build()

        let computedRules = {
            var rules: [NEOnDemandRule] = []
#if os(iOS)
            #expect(OnDemandModule.supportsCellular)
            let mobileRule = NEOnDemandRuleDisconnect()
            mobileRule.interfaceTypeMatch = .cellular
            rules.append(mobileRule)
#else
            #expect(OnDemandModule.supportsEthernet)
            let ethernetRule = NEOnDemandRuleDisconnect()
            ethernetRule.interfaceTypeMatch = .ethernet
            rules.append(ethernetRule)
#endif
            let wifiRule = NEOnDemandRuleDisconnect()
            wifiRule.interfaceTypeMatch = .wiFi
            wifiRule.ssidMatch = ["home", "nope"]
            rules.append(wifiRule)
            rules.append(NEOnDemandRuleConnect())
            return rules
        }()
        #expect(sut.neRules == computedRules)
    }

    @Test
    func givenIncludingPolicyWithCustomRules_whenGetRules_thenHasIgnoreExceptIncludedNetworks() throws {
        var module = OnDemandModule.Builder()
        module.policy = .including
        module.withMobileNetwork = true
        module.withEthernetNetwork = true
        module.withSSIDs = [
            "nope": true,
            "home": true,
            "yep": false
        ]

        let sut = module.build()

        let computedRules = {
            var rules: [NEOnDemandRule] = []
#if os(iOS)
            #expect(OnDemandModule.supportsCellular)
            let mobileRule = NEOnDemandRuleConnect()
            mobileRule.interfaceTypeMatch = .cellular
            rules.append(mobileRule)
#else
            #expect(OnDemandModule.supportsEthernet)
            let ethernetRule = NEOnDemandRuleConnect()
            ethernetRule.interfaceTypeMatch = .ethernet
            rules.append(ethernetRule)
#endif
            let wifiRule = NEOnDemandRuleConnect()
            wifiRule.interfaceTypeMatch = .wiFi
            wifiRule.ssidMatch = ["home", "nope"]
            rules.append(wifiRule)
            rules.append(NEOnDemandRuleIgnore())
            return rules
        }()
        #expect(sut.neRules == computedRules)
    }
}

private extension OnDemandModule {
    var neRules: [NEOnDemandRule] {
        neRules(.global)
    }
}
