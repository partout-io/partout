// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Event about the ``ConnectionStatus`` of a profile.
public struct OnConnectionStatus: Codable, Sendable {
    public let profileId: String
    public let status: ConnectionStatus
}

/// Callback reporting ``ConnectionStatus``.
public typealias OnConnectionStatusCallback = @Sendable (OnConnectionStatus) -> Void
