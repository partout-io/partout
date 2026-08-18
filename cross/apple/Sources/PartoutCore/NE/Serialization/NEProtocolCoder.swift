// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// Encodes and decodes a profile to and from `NETunnelProviderProtocol`.
public typealias NEProtocolCoder = NEProtocolEncoder & NEProtocolDecoder

/// Encodes a `Profile` for use in Network Extension.
public protocol NEProtocolEncoder: Sendable {
    /// Checks ownership of a `NETunnelProviderProtocol` for a given profile.
    func owns(_ protocolConfiguration: NETunnelProviderProtocol, for profileId: Profile.ID) -> Bool

    /// Encodes a `Profile` into a `NETunnelProviderProtocol`.
    /// - Parameters:
    ///   - profile: The profile to encode.
    /// - Returns: A `NETunnelProviderProtocol` for use with `NETunnelProviderManager`.
    func protocolConfiguration(from profile: Profile) throws -> NETunnelProviderProtocol
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
