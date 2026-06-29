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
