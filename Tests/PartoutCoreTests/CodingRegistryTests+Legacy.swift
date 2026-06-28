// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

// `withLegacyEncoding` only changes `string(fromProfile:)`; decode always probes
// V3, then V2, then V1, so these legacy decode checks stay unparameterized.
struct CodingRegistryLegacyTests {
    @Test
    func givenCoder_whenDecodeProfileEncodedWithLegacyV2_thenIsDecoded() throws {
        let registry = Registry(withKnown: true)
        let encoder = LegacyProfileEncoderV2(registry)
        let fixture = try newLegacyV2ProfileFixture(encoder)
        let encoded = try encoder.encode(fixture.profile.asCodableProfileV2)

        let sut = registry.withLegacyEncoding(false)
        let decoded = try sut.profile(fromString: encoded)
        #expect(decoded == fixture.profile)
    }

    @Test
    func givenLegacyV2_whenDecodeProfileWithUnknownModule_thenFailsWithUnknownModuleHandler() throws {
        let registry = Registry(allHandlers: [])
        let encoder = LegacyProfileEncoderV2(registry)
        let fixture = try newLegacyV2ProfileFixture(encoder)

        let error = #expect(throws: PartoutError.self) {
            _ = try encoder.decode(fixture.encoded)
        }
        #expect(error?.code == .unknownModuleHandler)
    }

    @Test
    func givenCoder_whenDecodeProfileEncodedByBuild4094WithLegacyV2_thenIsDecoded() throws {
        let sut = Registry(withKnown: true).withLegacyEncoding(false)
        let decoded = try sut.profile(fromString: Fixtures.build4094LegacyV2)
        let expected = try expectedBuild4094Profile(
            profileId: "045CF078-A158-400F-AFFA-675D7B5DA97F",
            dnsId: "C84056B9-4870-4F3C-AE7C-2E41F0ACA2E6",
            ipId: "24BAFB05-EF88-4841-B621-AABA6A700097",
            onDemandId: "23903CFD-8A18-4A45-9D3E-F828BA046B15",
            httpProxyId: "D035C850-2646-4B55-BCF3-15715ACF0B3F",
            openVPNId: "86C76417-1488-4359-91A4-A0CCDAB4031C",
            wireGuardId: "C2189B42-605E-4D52-AC36-402B68F6B3CC"
        )

        #expect(decoded == expected)
    }

    @Test
    func givenCoder_whenDecodeProfileEncodedByBuild4094WithV3_thenIsDecoded() throws {
        let sut = Registry(withKnown: true).withLegacyEncoding(false)
        let decoded = try sut.profile(fromString: Fixtures.build4094V3)
        let expected = try expectedBuild4094Profile(
            profileId: "0F9AE78B-1735-427D-BCDE-83CD8AA96F21",
            dnsId: "A6F3428A-FCA4-4D04-83E1-70C1071BC6A3",
            ipId: "EC5452E5-1D1F-46CF-A7F3-FF22B075272C",
            onDemandId: "09B9ACDA-2EC9-4B56-9B4E-EB91187ADBDA",
            httpProxyId: "63028907-B830-4D98-8F8E-A5EB8FBDD088",
            openVPNId: "DD9A9D88-AD1F-4829-80C4-0AA229AF97C6",
            wireGuardId: "90F13F3A-7DEE-4B24-96A8-2AE7CAE451F6"
        )

        #expect(decoded == expected)
    }
}

private extension CodingRegistryLegacyTests {
    func newLegacyV2ProfileFixture(_ encoder: LegacyProfileEncoderV2) throws -> LegacyProfileFixture {
        let profile = try newTestProfile()
        let encoded = try encoder.encode(profile.asCodableProfileV2)
        return LegacyProfileFixture(profile: profile, encoded: encoded)
    }

    func newTestProfile() throws -> Profile {
        let dnsModule = try DNSModule.Builder(
            id: UniqueID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            protocolType: .https,
            dohURL: "https://example.com/dns"
        ).build()
        let ipModule = IPModule.Builder(
            id: UniqueID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            mtu: 1280
        ).build()
        var builder = Profile.Builder(
            id: UniqueID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "legacy-profile",
            modules: [dnsModule, ipModule]
        )
        builder.userInfo = .object([
            "source": .string("legacy")
        ])
        return try builder.build()
    }

    func expectedBuild4094Profile(
        profileId: String,
        dnsId: String,
        ipId: String,
        onDemandId: String,
        httpProxyId: String,
        openVPNId: String,
        wireGuardId: String
    ) throws -> Profile {
        var openVPNBuilder = OpenVPN.Configuration.Builder()
        openVPNBuilder.ca = OpenVPN.CryptoContainer(pem: "")
        openVPNBuilder.cipher = .aes128cbc
        openVPNBuilder.remotes = [
            try ExtendedEndpoint("host.name", EndpointProtocol(.tcp, 80))
        ]

        var wireGuardBuilder = WireGuard.Configuration.Builder(privateKey: "")
        wireGuardBuilder.peers = [WireGuard.RemoteInterface.Builder(publicKey: "")]

        let modules: [Module] = [
            try DNSModule.Builder(
                id: requireUniqueID(dnsId),
                servers: ["1.1.1.1"]
            ).build(),
            IPModule.Builder(
                id: requireUniqueID(ipId),
                ipv4: IPSettings(subnet: try Subnet("1.2.3.4", 16))
            ).build(),
            OnDemandModule.Builder(
                id: requireUniqueID(onDemandId)
            ).build(),
            try HTTPProxyModule.Builder(
                id: requireUniqueID(httpProxyId),
                address: "1.1.1.1",
                port: 1080
            ).build(),
            try OpenVPNModule.Builder(
                id: requireUniqueID(openVPNId),
                configurationBuilder: openVPNBuilder
            ).build(),
            try WireGuardModule.Builder(
                id: requireUniqueID(wireGuardId),
                configurationBuilder: wireGuardBuilder
            ).build()
        ]

        return try Profile.Builder(
            id: requireUniqueID(profileId),
            modules: modules,
            activatingModules: false
        ).build()
    }

    func requireUniqueID(_ string: String) -> UniqueID {
        guard let id = UniqueID(uuidString: string) else {
            fatalError("Invalid fixture UUID: \(string)")
        }
        return id
    }
}

private struct LegacyProfileFixture {
    let profile: Profile
    let encoded: String
}

private enum Fixtures {
    static let build4094LegacyV2 = """
    {"activeModulesIds":[],"name":"","modules":[{"moduleType":"DNS","payload":{"id":"C84056B9-4870-4F3C-AE7C-2E41F0ACA2E6","inheritsVPN":false,"protocolType":{"cleartext":{}},"servers":["1.1.1.1"]}},{"moduleType":"IP","payload":{"id":"24BAFB05-EF88-4841-B621-AABA6A700097","ipv4":{"subnets":["1.2.3.4\\/16"],"includedRoutes":[],"excludedRoutes":[]}}},{"moduleType":"OnDemand","payload":{"id":"23903CFD-8A18-4A45-9D3E-F828BA046B15","withOtherNetworks":[],"withSSIDs":{},"policy":"any"}},{"moduleType":"HTTPProxy","payload":{"proxy":"1.1.1.1:1080","bypassDomains":[],"id":"D035C850-2646-4B55-BCF3-15715ACF0B3F"}},{"moduleType":"OpenVPN","payload":{"requiresInteractiveCredentials":false,"id":"86C76417-1488-4359-91A4-A0CCDAB4031C","configuration":{"ca":"","staticChallenge":false,"remotes":["host.name:TCP:80"],"cipher":"AES-128-CBC"}}},{"moduleType":"WireGuard","payload":{"configuration":{"interface":{"privateKey":"","addresses":[]},"peers":[{"publicKey":"","allowedIPs":[]}]},"id":"C2189B42-605E-4D52-AC36-402B68F6B3CC"}}],"version":2,"id":"045CF078-A158-400F-AFFA-675D7B5DA97F"}
    """

    static let build4094V3 = """
    {"version":2,"id":"0F9AE78B-1735-427D-BCDE-83CD8AA96F21","name":"","modules":[{"value":{"protocolType":{"type":"cleartext"},"servers":["1.1.1.1"],"id":"A6F3428A-FCA4-4D04-83E1-70C1071BC6A3","inheritsVPN":false},"type":"DNS"},{"value":{"id":"EC5452E5-1D1F-46CF-A7F3-FF22B075272C","ipv4":{"subnets":["1.2.3.4\\/16"],"includedRoutes":[],"excludedRoutes":[]}},"type":"IP"},{"type":"OnDemand","value":{"withOtherNetworks":[],"policy":"any","withSSIDs":{},"id":"09B9ACDA-2EC9-4B56-9B4E-EB91187ADBDA"}},{"type":"HTTPProxy","value":{"id":"63028907-B830-4D98-8F8E-A5EB8FBDD088","proxy":"1.1.1.1:1080","bypassDomains":[]}},{"type":"OpenVPN","value":{"id":"DD9A9D88-AD1F-4829-80C4-0AA229AF97C6","configuration":{"staticChallenge":false,"ca":"","cipher":"AES-128-CBC","remotes":["host.name:TCP:80"]},"requiresInteractiveCredentials":false}},{"type":"WireGuard","value":{"configuration":{"interface":{"addresses":[],"privateKey":""},"peers":[{"publicKey":"","allowedIPs":[]}]},"id":"90F13F3A-7DEE-4B24-96A8-2AE7CAE451F6"}}],"activeModulesIds":[]}
    """
}
