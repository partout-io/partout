// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// ``NEProtocolCoder`` encoding to and from a keychain.
public struct KeychainNEProtocolCoderV2: NEProtocolCoder {
    private let ctx: PartoutLoggerContext

    private let tunnelBundleIdentifier: String

    private let coder: ProfileCoder

    private let keychain: Keychain

    public init(_ ctx: PartoutLoggerContext, tunnelBundleIdentifier: String, coder: ProfileCoder, keychain: Keychain) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.coder = coder
        self.keychain = keychain
    }

    public func protocolConfiguration(from profile: Profile, title: (Profile) -> String) throws -> NETunnelProviderProtocol {
        let encoded = try coder.string(fromProfile: profile)

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
        return try coder.profile(fromString: encoded)
    }

    public func removeProfile(withId profileId: Profile.ID) throws {
        keychain.removePassword(for: profileId.uuidString)
    }

    public func purge(managers: [NETunnelProviderManager]) async {
    }

    public func recoverProfiles(notReferencedBy managers: [NETunnelProviderManager]) async -> [Profile] {
        // Retain the keychain entries referenced by valid managers.
        let keychainToRetain: Set<Data> = managers.reduce(into: []) {
            if let item = $1.protocolConfiguration?.passwordReference {
                $0.insert(item)
            }
        }

        // Return complete profiles from unreferenced keychain entries. Undecodable
        // entries are retained because this keychain may contain unrelated or
        // temporarily inaccessible data.
        var staleProfiles: [Profile] = []
        var staleProfileIds: Set<Profile.ID> = []
        do {
            let entries = try keychain.allPasswordReferences()
            entries.forEach { ref in
                guard !keychainToRetain.contains(ref) else { return }
                do {
                    let pwd = try keychain.password(forReference: ref)
                    let profile = try coder.profile(fromString: pwd)
                    if staleProfileIds.insert(profile.id).inserted {
                        staleProfiles.append(profile)
                    }
                } catch {
                    pp_log(ctx, .os, .error, "Unable to recover keychain reference, retain: \(error)")
                }
            }
        } catch {
            pp_log(ctx, .os, .error, "Unable to fetch keychain items: \(error)")
        }
        return staleProfiles
    }
}
