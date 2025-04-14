//
//  OnDemandModuleRulesTests.swift
//  Partout
//
//  Created by Davide De Rosa on 4/13/24.
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
@testable import PartoutNE
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
