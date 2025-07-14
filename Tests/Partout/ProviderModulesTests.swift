//
//  ProviderModulesTests.swift
//  Partout
//
//  Created by Davide De Rosa on 1/29/25.
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
import Partout
import XCTest

final class ProviderModulesTests: XCTestCase {
    private let mockId = ProviderID(rawValue: "hideme")

    private let resourcesURL = Bundle.module.url(forResource: "Resources", withExtension: nil)

#if canImport(_PartoutOpenVPNCore)
    func test_givenProviderModule_whenOpenVPN_thenResolves() throws {
        var sut = ProviderModule.Builder()
        sut.providerId = mockId
        sut.providerModuleType = .openVPN
        sut.entity = try openVPNEntity()

        let module = try sut.tryBuild()
        XCTAssertFalse(module.isFinal)
        let resolvedModule = try OpenVPNProviderResolver(.global).resolved(from: module, deviceId: "")
        XCTAssertTrue(resolvedModule.isFinal)
        let typedModule = try XCTUnwrap(resolvedModule as? OpenVPNModule)

        XCTAssertEqual(typedModule.configuration?.renegotiatesAfter, 900)
        XCTAssertEqual(typedModule.configuration?.remotes, [
            try .init("be-v4.hideservers.net", .init(.udp, 3000)),
            try .init("be-v4.hideservers.net", .init(.udp, 3010)),
            try .init("be-v4.hideservers.net", .init(.tcp, 3000)),
            try .init("be-v4.hideservers.net", .init(.tcp, 3020))
        ])
    }
#endif

#if canImport(_PartoutWireGuardCore)
//    func test_givenProviderModule_whenWireGuard_thenResolves() throws {
//        var sut = ProviderModule.Builder()
//        sut.providerId = .hideme
//        sut.providerModuleType = .wireGuard
//        let module = try sut.tryBuild()
//        let resolvedModule = try module.resolvedModule(with: registry)
//        XCTAssertTrue(resolvedModule is WireGuardModule)
//    }
#endif
}

private extension ProviderModulesTests {
#if canImport(_PartoutOpenVPNCore)
    func openVPNEntity() throws -> ProviderEntity {
        let presetURL = try XCTUnwrap(resourcesURL?.appendingPathComponent("preset.openvpn.json"))
        let templateData = try Data(contentsOf: presetURL)

        return ProviderEntity(
            server: .init(
                metadata: .init(
                    providerId: mockId,
                    categoryName: "default",
                    countryCode: "BE",
                    otherCountryCodes: nil,
                    area: nil
                ),
                serverId: "be-v4",
                hostname: "be-v4.hideservers.net",
                ipAddresses: nil,
                supportedModuleTypes: [.openVPN],
                supportedPresetIds: nil
            ),
            preset: .init(
                providerId: mockId,
                presetId: "default",
                description: "Default",
                moduleType: .openVPN,
                templateData: templateData
            ),
            heuristic: nil
        )
    }
#endif
}
