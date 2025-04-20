//
//  KeychainNEProtocolCoder.swift
//  Partout
//
//  Created by Davide De Rosa on 2/16/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NetworkExtension
import PartoutCore

/// ``NEProtocolCoder`` encoding to and from a `Keychain`.
public struct KeychainNEProtocolCoder: NEProtocolCoder {
    private let tunnelBundleIdentifier: String

    private let registry: Registry

    private let coder: ProfileCoder

    private let keychain: Keychain

    public init(tunnelBundleIdentifier: String, registry: Registry, coder: ProfileCoder, keychain: Keychain) {
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

        // FIXME: #11, restore purge after confirming safe migration
        return

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
                pp_log(.ne, .error, "Unable to decode profile, will delete NE manager '\($0.localizedDescription ?? "")': \(error)")
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
            pp_log(.ne, .error, "Unable to fetch keychain items: \(error)")
        }
    }
}
