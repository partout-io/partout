//
//  ProviderNEProtocolCoder.swift
//  Partout
//
//  Created by Davide De Rosa on 3/27/24.
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

/// ``NEProtocolCoder`` encoding to and from the `providerConfiguration`.
public struct ProviderNEProtocolCoder: NEProtocolCoder {
    private let ctx: PartoutContext

    private let tunnelBundleIdentifier: String

    private let registry: Registry

    private let coder: ProfileCoder

    public init(_ ctx: PartoutContext, tunnelBundleIdentifier: String, registry: Registry, coder: ProfileCoder) {
        self.ctx = ctx
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.registry = registry
        self.coder = coder
    }

    public func protocolConfiguration(from profile: Profile, title: (Profile) -> String) throws -> NETunnelProviderProtocol {
        let encoded = try registry.encodedProfile(profile, with: coder)

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.providerConfiguration = [Self.providerKey: encoded]
        proto.serverAddress = NEProtocolCoderServerAddress
        proto.disconnectOnSleep = profile.disconnectsOnSleep
        return proto
    }

    public func profile(from protocolConfiguration: NETunnelProviderProtocol) throws -> Profile {
        guard let encoded = protocolConfiguration.providerConfiguration?[Self.providerKey] as? String else {
            throw PartoutError(.decoding)
        }
        return try registry.decodedProfile(from: encoded, with: coder)
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
