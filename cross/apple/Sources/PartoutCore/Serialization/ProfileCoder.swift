// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Both a ``ProfileEncoder`` and ``ProfileDecoder``.
public protocol ProfileCoder: ProfileEncoder, ProfileDecoder {}

/// Able to encode a ``Profile``.
public protocol ProfileEncoder: Sendable {
    func string(fromProfile profile: Profile) throws -> String
}

/// Able to decode a ``Profile``.
public protocol ProfileDecoder: Sendable {
    func profile(fromString string: String) throws -> Profile
}
