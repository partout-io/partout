// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Common options to give to ``TunnelController``.
public struct TunnelControllerOptions: Codable, Sendable {
    public var dnsFallbackServers: [String] = []
    public var logsSnapshots: Bool = false

    public init() {}
}
