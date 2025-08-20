// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import PartoutInterfaces
import Testing

struct ProviderModulesTests {
    private let mockId = ProviderID(rawValue: "hideme")

    private let resourcesURL = Bundle.module.url(forResource: "Resources", withExtension: nil)

#if canImport(PartoutOpenVPN)
    @Test
    func givenProviderModule_whenOpenVPN_thenResolves() throws {
        var sut = ProviderModule.Builder()
        sut.providerId = mockId
        sut.providerModuleType = .openVPN
        sut.entity = try openVPNEntity()

        let module = try sut.tryBuild()
        #expect(!module.isFinal)
        let resolvedModule = try OpenVPNProviderResolver(.global).resolved(from: module)
        #expect(resolvedModule.isFinal)
        let typedModule = try #require(resolvedModule as? OpenVPNModule)

        #expect(typedModule.configuration?.renegotiatesAfter == 900)
        #expect(typedModule.configuration?.remotes == [
            try .init("be-v4.hideservers.net", .init(.udp, 3000)),
            try .init("be-v4.hideservers.net", .init(.udp, 3010)),
            try .init("be-v4.hideservers.net", .init(.tcp, 3000)),
            try .init("be-v4.hideservers.net", .init(.tcp, 3020))
        ])
    }
#endif

#if canImport(PartoutWireGuard)
    @Test
    func givenProviderModule_whenWireGuard_thenResolves() throws {
        let deviceId = "device_id"
        let addresses = ["8.9.10.11/32"]

        var sut = ProviderModule.Builder()
        sut.providerId = mockId
        sut.providerModuleType = .wireGuard

        let session = WireGuardProviderStorage.Session(privateKey: "", publicKey: "")
            .with(peer: WireGuardProviderStorage.Peer(id: deviceId, creationDate: Date(), addresses: addresses))
        var storage = WireGuardProviderStorage()
        storage.sessions = [deviceId: session]
        try sut.setOptions(storage, for: .wireGuard)

        sut.entity = try wireGuardEntity()

        let module = try sut.tryBuild()
        let resolvedModule = try WireGuardProviderResolver(.global, deviceId: deviceId)
            .resolved(from: module)
        #expect(resolvedModule is WireGuardModule)

        let wg = try #require(resolvedModule as? WireGuardModule)
        #expect(wg.configuration?.interface.addresses.map(\.rawValue) == addresses)
        #expect(wg.configuration?.interface.mtu == nil)
        #expect(wg.configuration?.peers.first?.publicKey.rawValue == "")
        #expect(wg.configuration?.peers.first?.endpoint?.address.rawValue == "1.2.3.4")
        #expect(wg.configuration?.peers.first?.endpoint?.port == 12345)
        #expect(wg.configuration?.peers.first?.allowedIPs.map(\.rawValue) == ["0.0.0.0/0", "::/0"])
        #expect(wg.configuration?.peers.first?.keepAlive == nil)
    }
#endif
}

private extension ProviderModulesTests {
#if canImport(PartoutOpenVPN)
    func openVPNEntity() throws -> ProviderEntity {
        let presetURL = try #require(resourcesURL?.appendingPathComponent("preset.openvpn.json"))
        let templateData = try Data(contentsOf: presetURL)

        return ProviderEntity(
            server: mockServer(withIPAddresses: false),
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

#if canImport(PartoutWireGuard)
    func wireGuardEntity() throws -> ProviderEntity {
        let presetURL = try #require(resourcesURL?.appendingPathComponent("preset.wireguard.json"))
        let templateData = try Data(contentsOf: presetURL)

        return ProviderEntity(
            server: mockServer(withIPAddresses: true),
            preset: .init(
                providerId: mockId,
                presetId: "default",
                description: "Default",
                moduleType: .wireGuard,
                templateData: templateData
            ),
            heuristic: nil
        )
    }
#endif

    func mockServer(withIPAddresses: Bool) -> ProviderServer {
        ProviderServer(
            metadata: .init(
                providerId: mockId,
                categoryName: "default",
                countryCode: "BE",
                otherCountryCodes: nil,
                area: nil
            ),
            serverId: "be-v4",
            hostname: "be-v4.hideservers.net",
            ipAddresses: withIPAddresses ? [Data(hex: "01020304")] : nil, // 1.2.3.4
            supportedModuleTypes: {
                var list: [ModuleType] = []
#if canImport(PartoutOpenVPN)
                list.append(.openVPN)
#endif
#if canImport(PartoutWireGuard)
                list.append(.wireGuard)
#endif
                return list
            }(),
            supportedPresetIds: nil,
            userInfo: [
                "wgPublicKey": ""
            ]
        )
    }
}
