// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import Partout
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
    func givenCoder_whenDecodeProfileEncodedWithLegacyV1_thenIsDecoded() throws {
        let registry = Registry(withKnown: true)
        let fixture = try newLegacyV1ProfileFixture()
        let encoded = fixture.encoded

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
    func givenLegacyV1_whenDecodeProfileWithUnknownModule_thenDropsUnknownModule() throws {
        let registry = Registry(allHandlers: [])
        let encoder = LegacyProfileEncoderV1()
        let fixture = try newLegacyV1ProfileFixture()
        var expectedBuilder = fixture.profile.builder()
        expectedBuilder.modules = []
        let expected = try expectedBuilder.build()

        let legacyDecoded = try encoder.decodedProfile(
            from: fixture.encoded,
            with: registry
        )
        let sut = registry.withLegacyEncoding(false)
        let decoded = try sut.profile(fromString: fixture.encoded)

        #expect(legacyDecoded == expected)
        #expect(decoded == expected)
        #expect(decoded.modules.isEmpty)
    }
}

private extension CodingRegistryLegacyTests {
    func newLegacyV2ProfileFixture(_ encoder: LegacyProfileEncoderV2) throws -> LegacyProfileFixture {
        let profile = try newTestProfile()
        let encoded = try encoder.encode(profile.asCodableProfileV2)
        return LegacyProfileFixture(profile: profile, encoded: encoded)
    }

    func newLegacyV1ProfileFixture() throws -> LegacyProfileFixture {
        let profile = try newTestProfile()
        let modules = try profile.modules.map { module in
            guard let encodableModule = module as? (any Module & Encodable) else {
                throw PartoutError(.encoding)
            }
            return try LegacyModuleWrapper(encodableModule)
        }
        let payload = LegacyCodableProfile(
            version: profile.version,
            id: profile.id,
            name: profile.name,
            modules: modules,
            activeModulesIds: profile.activeModulesIds,
            behavior: profile.behavior,
            userInfo: try profile.userInfo.map { try JSONEncoder().encode($0) }
        )
        let data = try JSONEncoder().encode(payload)
        let encoded = data.base64EncodedString()
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
}

private struct LegacyProfileFixture {
    let profile: Profile
    let encoded: String
}
