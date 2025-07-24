//
//  NEProtocolCoder.swift
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

/// Encodes and decodes a ``/PartoutCore/Profile`` to and from `NETunnelProviderProtocol`.
public typealias NEProtocolCoder = NEProtocolEncoder & NEProtocolDecoder

/// Encodes a `Profile` for use in Network Extension.
public protocol NEProtocolEncoder: Sendable {

    /// Encodes a `Profile` into a `NETunnelProviderProtocol`.
    /// - Parameters:
    ///   - profile: The profile to encode.
    ///   - title: The title as function of the profile.
    /// - Returns: A `NETunnelProviderProtocol` for use with `NETunnelProviderManager`.
    func protocolConfiguration(from profile: Profile, title: (Profile) -> String) throws -> NETunnelProviderProtocol

    /// Removes a profile from the underlying storage.
    /// - Parameters:
    ///   - profileId: The ID of the profile to remove.
    func removeProfile(withId profileId: Profile.ID) throws

    /// Purges stale data from existing profiles.
    /// - Parameters:
    ///   - managers: The list of `NETunnelProviderManager` to review for potentially stale data.
    func purge(managers: [NETunnelProviderManager]) async
}

/// Decodes a `Profile` for use in Network Extension.
public protocol NEProtocolDecoder: Sendable {

    /// Decodes a `Profile` from a `NETunnelProviderProtocol`.
    /// - Parameters:
    ///   - protocolConfiguration: The `NETunnelProviderProtocol` to decode.
    /// - Returns: The decoded profile.
    func profile(from protocolConfiguration: NETunnelProviderProtocol) throws -> Profile
}

let NEProtocolCoderServerAddress = "127.0.0.1"
