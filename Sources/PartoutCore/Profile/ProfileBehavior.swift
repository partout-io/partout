// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Advanced flags affecting the behavior of a ``Profile``.
public struct ProfileBehavior: Hashable, Codable, Sendable {

    /// Disconnects when the device goes to sleep.
    public var disconnectsOnSleep: Bool

    /// Attempts to route as much traffic as possible through the tunnel.
    public var includesAllNetworks: Bool?

    public init() {
        disconnectsOnSleep = false
        includesAllNetworks = false
    }
}
