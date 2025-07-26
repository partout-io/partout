// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import Partout
import XCTest

final class ProviderModulesTests: XCTestCase {
    private let mockId = ProviderID(rawValue: "hideme")

    private let resourcesURL = Bundle.module.url(forResource: "Resources", withExtension: nil)

#if canImport(PartoutOpenVPN)
    func test_givenProviderModule_whenOpenVPN_thenResolves() throws {
        var sut = ProviderModule.Builder()
        sut.providerId = mockId
        sut.providerModuleType = .openVPN
        sut.entity = try openVPNEntity()

        let module = try sut.tryBuild()
        XCTAssertFalse(module.isFinal)
        let resolvedModule = try OpenVPNProviderResolver(.global).resolved(from: module, on: "")
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

#if canImport(PartoutWireGuard)
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
#if canImport(PartoutOpenVPN)
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
