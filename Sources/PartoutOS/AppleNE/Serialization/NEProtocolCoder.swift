// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Encodes and decodes a profile to and from `NETunnelProviderProtocol`.
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
