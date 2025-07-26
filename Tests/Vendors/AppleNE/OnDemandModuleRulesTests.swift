// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import _PartoutVendorsAppleNE
import Foundation
import NetworkExtension
import PartoutCore
import XCTest

final class OnDemandModuleRulesTests: XCTestCase {
    func test_givenAnyPolicy_whenGetRules_thenHasConnect() {
        var module = OnDemandModule.Builder()
        module.policy = .any

        let sut = module.tryBuild()

        XCTAssertEqual(sut.neRules, [
            NEOnDemandRuleConnect()
        ])
    }

    func test_givenExcludingPolicy_whenGetRules_thenHasConnect() {
        var module = OnDemandModule.Builder()
        module.policy = .excluding

        let sut = module.tryBuild()

        XCTAssertEqual(sut.neRules, [
            NEOnDemandRuleConnect()
        ])
    }

    func test_givenExcludingPolicyWithCustomRules_whenGetRules_thenHasConnectExceptExcludedNetworks() throws {
        var module = OnDemandModule.Builder()
        module.policy = .excluding
        module.withMobileNetwork = true
        module.withEthernetNetwork = true
        module.withSSIDs = [
            "nope": true,
            "home": true,
            "yep": false
        ]

        let sut = module.tryBuild()

        XCTAssertEqual(sut.neRules, {
            var rules: [NEOnDemandRule] = []
#if os(iOS)
            XCTAssertTrue(OnDemandModule.supportsCellular)
            let mobileRule = NEOnDemandRuleDisconnect()
            mobileRule.interfaceTypeMatch = .cellular
            rules.append(mobileRule)
#else
            XCTAssertTrue(OnDemandModule.supportsEthernet)
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
        }())
    }

    func test_givenIncludingPolicyWithCustomRules_whenGetRules_thenHasIgnoreExceptIncludedNetworks() throws {
        var module = OnDemandModule.Builder()
        module.policy = .including
        module.withMobileNetwork = true
        module.withEthernetNetwork = true
        module.withSSIDs = [
            "nope": true,
            "home": true,
            "yep": false
        ]

        let sut = module.tryBuild()

        XCTAssertEqual(sut.neRules, {
            var rules: [NEOnDemandRule] = []
#if os(iOS)
            XCTAssertTrue(OnDemandModule.supportsCellular)
            let mobileRule = NEOnDemandRuleConnect()
            mobileRule.interfaceTypeMatch = .cellular
            rules.append(mobileRule)
#else
            XCTAssertTrue(OnDemandModule.supportsEthernet)
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
        }())
    }
}

private extension OnDemandModule {
    var neRules: [NEOnDemandRule] {
        neRules(.global)
    }
}
