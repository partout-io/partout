// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// ``NEProtocolCoder`` encoding to and from a `NETunnelProviderProtocol.providerConfiguration`.
public struct ProviderNEProtocolCoder: NEProtocolCoder {
    private let ctx: PartoutLoggerContext

    private let tunnelBundleIdentifier: String

    private let coder: ProfileCoder

    private let uid: Int

    public init(
        _ ctx: PartoutLoggerContext,
        tunnelBundleIdentifier: String,
        coder: ProfileCoder,
        uid: Int
    ) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.coder = coder
        self.uid = uid
    }

    public func owns(_ protocolConfiguration: NETunnelProviderProtocol, for profileId: Profile.ID) -> Bool {
        // Best-effort, UID was introduced later. Assume owned if UID is missing.
        guard let cfg = protocolConfiguration.providerConfiguration else { return true }
        guard let protoUID = cfg[Self.uidKey] as? Int else { return true }
        return protoUID == uid
    }

    public func protocolConfiguration(from profile: Profile) throws -> NETunnelProviderProtocol {
        let encoded = try coder.string(fromProfile: profile)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.providerConfiguration = [
            Self.profileKey: encoded,
            Self.uidKey: uid
        ]
        proto.serverAddress = NEProtocolCoderServerAddress
        proto.disconnectOnSleep = profile.disconnectsOnSleep
#if !os(tvOS)
        proto.includeAllNetworks = profile.includesAllNetworks
#endif
        return proto
    }

    public func profile(from protocolConfiguration: NETunnelProviderProtocol) throws -> Profile {
        guard let encoded = protocolConfiguration.providerConfiguration?[Self.profileKey] as? String else {
            throw PartoutError(.decoding)
        }
        return try coder.profile(fromString: encoded)
    }
}

extension ProviderNEProtocolCoder {
    static let profileKey = "Profile"
    static let uidKey = "UID"
}
