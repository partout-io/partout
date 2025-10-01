// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// ``NEProtocolCoder`` encoding to and from a ``/PartoutCore/Keychain``.
public struct KeychainNEProtocolCoder: NEProtocolCoder {
    private let ctx: PartoutLoggerContext

    private let tunnelBundleIdentifier: String

    private let registry: Registry

    private let coder: ProfileCoder

    private let keychain: Keychain

    public init(_ ctx: PartoutLoggerContext, tunnelBundleIdentifier: String, registry: Registry, coder: ProfileCoder, keychain: Keychain) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.registry = registry
        self.coder = coder
        self.keychain = keychain
    }

    public func protocolConfiguration(from profile: Profile, title: (Profile) -> String) throws -> NETunnelProviderProtocol {
        let encoded = try registry.encodedProfile(profile, with: coder)

        let passwordReference = try keychain.set(
            password: encoded,
            for: profile.id.uuidString,
            label: title(profile)
        )

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
        return try registry.decodedProfile(from: encoded, with: coder)
    }

    public func removeProfile(withId profileId: Profile.ID) throws {
        keychain.removePassword(for: profileId.uuidString)
    }

    public func purge(managers: [NETunnelProviderManager]) async {

        // remove those managers (plus their keychain entry) we cannot decode a profile from
        var managersToRemove: [NETunnelProviderManager] = []
        var keychainToRetain: [Data] = []
        managers.forEach {
            do {
                guard let proto = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                    throw PartoutError(.decoding)
                }
                _ = try profile(from: proto)
                if let item = $0.protocolConfiguration?.passwordReference {
                    keychainToRetain.append(item)
                }
            } catch {
                pp_log(ctx, .os, .error, "Unable to decode profile, will delete NE manager '\($0.localizedDescription ?? "")': \(error)")
                managersToRemove.append($0)
            }
        }
        for manager in managersToRemove {
            if let ref = manager.protocolConfiguration?.passwordReference {
                keychain.removePassword(forReference: ref)
            }
            try? await manager.removeFromPreferences()
        }

        // remove keychain entries that do not belong to any active manager
        do {
            let entries = try keychain.allPasswordReferences()
            entries.forEach {
                if !keychainToRetain.contains($0) {
                    keychain.removePassword(forReference: $0)
                }
            }
        } catch {
            pp_log(ctx, .os, .error, "Unable to fetch keychain items: \(error)")
        }
    }
}
