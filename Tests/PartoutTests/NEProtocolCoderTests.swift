// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(NetworkExtension)

import Partout
@testable import PartoutOS
import Testing

struct NEProtocolCoderTests {
    let registry = Registry(withKnown: true)

    @Test(arguments: [true, false])
    func givenProfile_whenEncodeToProvider_thenDecodes(legacy: Bool) throws {
        let profile = try newProfile()
        let coder = registry.withLegacyEncoding(legacy)
        let sut = ProviderNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: coder
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.providerConfiguration?[ProviderNEProtocolCoder.providerKey] as? String != nil)

        let decodedProfile = try sut.profile(from: proto)
        #expect(decodedProfile == profile)
    }

    @Test(arguments: [true, false])
    func givenProfile_whenEncodeToKeychain_thenDecodes(legacy: Bool) throws {
        let profile = try newProfile()
        let coder = registry.withLegacyEncoding(legacy)
        let sut = KeychainNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: coder,
            keychain: MockKeychain()
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.providerConfiguration == nil)

        let decodedProfile = try sut.profile(from: proto)
        #expect(decodedProfile == profile)
    }
}

// MARK: - Helpers

private extension NEProtocolCoderTests {
    var bundleIdentifier: String {
        "com.example.MyTunnel"
    }

    func newProfile() throws -> Profile {
        var builder = Profile.Builder()
        builder.name = "foobar"
        builder.modules.append(try DNSModule.Builder(servers: ["2.4.2.4"]).build())
        builder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080, pacURLString: "http://proxy.pac").build())
        builder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).build())
        builder.modules.append(OnDemandModule.Builder().build())
        return try builder.build()
    }
}

private final class MockKeychain: Keychain {
    func set(password: String, for username: String, label: String?) throws -> Data {
        guard let reference = password.data(using: .utf8) else {
            throw PartoutError(.encoding)
        }
        return reference
    }

    func removePassword(for username: String) -> Bool {
        fatalError("Unused")
    }

    func removePassword(forReference reference: Data) -> Bool {
        fatalError("Unused")
    }

    func password(for username: String) throws -> String {
        fatalError("Unused")
    }

    func passwordReference(for username: String) throws -> Data {
        fatalError("Unused")
    }

    func allPasswordReferences() throws -> [Data] {
        fatalError("Unused")
    }

    func password(forReference reference: Data) throws -> String {
        guard let string = String(data: reference, encoding: .utf8) else {
            throw PartoutError(.decoding)
        }
        return string
    }
}

#endif
