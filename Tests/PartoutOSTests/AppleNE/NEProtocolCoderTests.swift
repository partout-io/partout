// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(NetworkExtension)

import Foundation
import NetworkExtension
@testable import PartoutOS
import Testing

struct NEProtocolCoderTests {
    private let registry = Registry(withKnown: true)

    @Test(arguments: CoderKind.allCases)
    func roundTripPreservesProfileAndCommonProtocolFields(_ kind: CoderKind) throws {
        let profile = try newProfile()
        let (sut, _) = try makeCoder(kind, containing: profile)

        let proto = try sut.protocolConfiguration(from: profile)

        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.serverAddress == NEProtocolCoderServerAddress)
        #expect(proto.disconnectOnSleep)
#if !os(tvOS)
        #expect(proto.includeAllNetworks)
#endif
        #expect(try sut.profile(from: proto) == profile)
    }

    @Test(arguments: CoderKind.allCases)
    func malformedProtocolIsRejected(_ kind: CoderKind) throws {
        let profile = try newProfile()
        let (sut, _) = try makeCoder(kind, containing: profile)

        #expect(throws: PartoutError.self) {
            try sut.profile(from: NETunnelProviderProtocol())
        }
    }

    @Test
    func providerCoderStoresProfileOnlyInProviderConfiguration() throws {
        let profile = try newProfile()
        let (sut, _) = try makeCoder(.provider, containing: profile)

        let proto = try sut.protocolConfiguration(from: profile)

        #expect(proto.providerConfiguration?[ProviderNEProtocolCoder.providerKey] as? String != nil)
        #expect(proto.passwordReference == nil)
    }

    @Test
    func currentKeychainCoderUsesExternalReferenceWithoutWriting() throws {
        let profile = try newProfile()
        let (sut, keychain) = try makeCoder(.keychain, containing: profile)
        let expectedReference = keychain.reference(for: profile.id.uuidString)

        let proto = try sut.protocolConfiguration(from: profile)

        #expect(proto.providerConfiguration == nil)
        #expect(proto.passwordReference == expectedReference)
        #expect(keychain.setCalls.isEmpty)
        #expect(keychain.referenceLookups == [profile.id.uuidString])
    }

    @Test
    func currentKeychainCoderPropagatesMissingExternalReference() throws {
        let profile = try newProfile()
        let sut = KeychainNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: CodingRegistry(registry: registry),
            keychain: MockKeychain()
        )

        #expect(throws: PartoutError.self) {
            try sut.protocolConfiguration(from: profile)
        }
    }

    @Test
    func legacyKeychainCoderWritesEncodedProfileWithTitleMetadata() throws {
        let profile = try newProfile()
        let coder = CodingRegistry(registry: registry)
        let keychain = MockKeychain()
        let sut = KeychainNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: coder,
            keychain: keychain,
            legacyOptions: .init(title: { "VPN: \($0.name)" })
        )

        let proto = try sut.protocolConfiguration(from: profile)
        let call = try #require(keychain.setCalls.first)

        #expect(keychain.setCalls.count == 1)
        #expect(call.username == profile.id.uuidString)
        #expect(try coder.profile(fromString: call.password) == profile)
        #expect(call.label == "VPN: \(profile.name)")
        #expect(proto.passwordReference == keychain.reference(for: profile.id.uuidString))
        #expect(try sut.profile(from: proto) == profile)
    }
}

// MARK: - Helpers

private extension NEProtocolCoderTests {
    var bundleIdentifier: String {
        "com.example.MyTunnel"
    }

    func makeCoder(
        _ kind: CoderKind,
        containing profile: Profile
    ) throws -> (any NEProtocolCoder, MockKeychain) {
        let coder = CodingRegistry(registry: registry)
        let encoded = try coder.string(fromProfile: profile)
        let keychain = MockKeychain(passwords: [profile.id.uuidString: encoded])

        switch kind {
        case .provider:
            return (
                ProviderNEProtocolCoder(
                    .global,
                    tunnelBundleIdentifier: bundleIdentifier,
                    coder: coder
                ),
                keychain
            )
        case .keychain:
            return (
                KeychainNEProtocolCoder(
                    .global,
                    tunnelBundleIdentifier: bundleIdentifier,
                    coder: coder,
                    keychain: keychain
                ),
                keychain
            )
        }
    }

    func newProfile() throws -> Profile {
        var builder = Profile.Builder()
        builder.name = "foobar"
        builder.behavior = ProfileBehavior(disconnectsOnSleep: true, includesAllNetworks: true)
        builder.modules.append(try DNSModule.Builder(servers: ["2.4.2.4"]).build())
        builder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080, pacURLString: "http://proxy.pac").build())
        builder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).build())
        builder.modules.append(OnDemandModule.Builder().build())
        return try builder.build()
    }
}

enum CoderKind: CaseIterable, CustomTestStringConvertible, Sendable {
    case provider
    case keychain

    var testDescription: String {
        switch self {
        case .provider: "provider"
        case .keychain: "keychain"
        }
    }
}

private final class MockKeychain: Keychain, @unchecked Sendable {
    struct SetCall: Sendable {
        let password: String
        let username: String
        let label: String?
    }

    private let lock = NSLock()
    private var passwords: [String: String]
    private var mutableSetCalls: [SetCall] = []
    private var mutableReferenceLookups: [String] = []

    init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    var setCalls: [SetCall] {
        lock.withLock { mutableSetCalls }
    }

    var referenceLookups: [String] {
        lock.withLock { mutableReferenceLookups }
    }

    func reference(for username: String) -> Data {
        Data("reference:\(username)".utf8)
    }

    func set(password: String, for username: String, metadata: [KeychainMetadata]?) throws -> Data {
        let label = metadata?.compactMap { entry -> String? in
            guard case .label(let value) = entry else { return nil }
            return value
        }.first
        lock.withLock {
            passwords[username] = password
            mutableSetCalls.append(SetCall(password: password, username: username, label: label))
        }
        return reference(for: username)
    }

    func removePassword(for username: String) -> Bool {
        lock.withLock { passwords.removeValue(forKey: username) != nil }
    }

    func removePassword(forReference reference: Data) -> Bool {
        guard let username = username(from: reference) else { return false }
        return removePassword(for: username)
    }

    func password(for username: String) throws -> String {
        try lock.withLock {
            guard let password = passwords[username] else {
                throw PartoutError(.keychainItemNotFound)
            }
            return password
        }
    }

    func passwordReference(for username: String) throws -> Data {
        try lock.withLock {
            guard passwords[username] != nil else {
                throw PartoutError(.keychainItemNotFound)
            }
            mutableReferenceLookups.append(username)
        }
        return reference(for: username)
    }

    func allPasswordReferences() throws -> [Data] {
        lock.withLock { passwords.keys.map(reference(for:)) }
    }

    func password(forReference reference: Data) throws -> String {
        guard let username = username(from: reference) else {
            throw PartoutError(.decoding)
        }
        return try password(for: username)
    }

    private func username(from reference: Data) -> String? {
        guard let value = String(data: reference, encoding: .utf8),
              value.hasPrefix("reference:") else {
            return nil
        }
        return String(value.dropFirst("reference:".count))
    }
}
#endif
