// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// ``NEProtocolCoder`` encoding to and from a `NETunnelProviderProtocol.providerConfiguration`.
public struct ProviderNEProtocolCoder: NEProtocolCoder {
    private let ctx: PartoutLoggerContext

    private let tunnelBundleIdentifier: String

    private let registry: Registry

    public init(_ ctx: PartoutLoggerContext, tunnelBundleIdentifier: String, registry: Registry) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.registry = registry
    }

    public func protocolConfiguration(from profile: Profile, title: (Profile) -> String) throws -> NETunnelProviderProtocol {
        let encoded = try registry.json(fromProfile: profile)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.providerConfiguration = [Self.providerKey: encoded]
        proto.serverAddress = NEProtocolCoderServerAddress
        proto.disconnectOnSleep = profile.disconnectsOnSleep
#if !os(tvOS)
        proto.includeAllNetworks = profile.includesAllNetworks
#endif
        return proto
    }

    public func profile(from protocolConfiguration: NETunnelProviderProtocol) throws -> Profile {
        guard let encoded = protocolConfiguration.providerConfiguration?[Self.providerKey] as? String else {
            throw PartoutError(.decoding)
        }
        return try registry.compatibleProfile(fromString: encoded)
    }

    public func removeProfile(withId profileId: Profile.ID) throws {
    }

    public func purge(managers: [NETunnelProviderManager]) {
    }
}

extension ProviderNEProtocolCoder {
    static var providerKey: String {
        "Profile"
    }
}
