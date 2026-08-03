// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// ``NEProtocolCoder`` encoding to and from a keychain.
public struct KeychainNEProtocolCoder: NEProtocolCoder {
    public struct LegacyOptions: Sendable {
        public let title: @Sendable (Profile) -> String

        public init(title: @escaping @Sendable (Profile) -> String) {
            self.title = title
        }
    }

    private let ctx: PartoutLoggerContext

    private let tunnelBundleIdentifier: String

    private let coder: ProfileCoder

    private let keychain: Keychain

    private let legacyOptions: LegacyOptions?

    public init(
        _ ctx: PartoutLoggerContext,
        tunnelBundleIdentifier: String,
        coder: ProfileCoder,
        keychain: Keychain,
        legacyOptions: LegacyOptions? = nil
    ) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.coder = coder
        self.keychain = keychain
        self.legacyOptions = legacyOptions
    }

    public func protocolConfiguration(from profile: Profile) throws -> NETunnelProviderProtocol {
        let passwordReference: Data

        // Legacy had side-effect, actively writes to keychain
        if let legacyOptions {
            let encoded = try coder.string(fromProfile: profile)
            passwordReference = try keychain.set(
                password: encoded,
                for: profile.id.uuidString,
                metadata: [
                    .label(legacyOptions.title(profile))
                ]
            )
        } else {
            // Going forward, rely on external reference
            passwordReference = try keychain.passwordReference(for: profile.id.uuidString)
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.serverAddress = NEProtocolCoderServerAddress
        proto.passwordReference = passwordReference
        proto.disconnectOnSleep = profile.disconnectsOnSleep
#if !os(tvOS)
        proto.includeAllNetworks = profile.includesAllNetworks
#endif
        return proto
    }

    public func profile(from protocolConfiguration: NETunnelProviderProtocol) throws -> Profile {
        guard let passwordReference = protocolConfiguration.passwordReference else {
            throw PartoutError(.decoding)
        }
        let encoded = try keychain.password(forReference: passwordReference)
        return try coder.profile(fromString: encoded)
    }
}
