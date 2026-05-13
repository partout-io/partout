// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// The abstract protocol of a tunnel.
public protocol TunnelProtocol: TunnelStrategy {
    nonisolated var snapshots: [Profile.ID: TunnelSnapshot] { get }

    nonisolated var snapshotsStream: AsyncStream<[Profile.ID: TunnelSnapshot]> { get }

    func allEnvironments() async -> [Profile.ID: TunnelEnvironmentReader]

    func environment(for profileId: Profile.ID) async -> TunnelEnvironmentReader?
}

extension TunnelProtocol {
    public func sendMessage(_ message: Message.Input) async throws -> Message.Output? {
        guard let profileId = snapshots.keys.first else { return nil }
        return try await sendMessage(message, to: profileId)
    }
}
