// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Abstracts tunnel configuration.
public protocol TunnelController: AnyObject, Sendable {
    func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> TunInterface

    func configureSockets(with descriptors: [SocketDescriptor]) throws

    func reportSnapshot(_ snapshot: TunnelSnapshot)

    func clearTunnelSettings(withKillSwitch: Bool) async

    func setReasserting(_ reasserting: Bool)

    func cancelTunnelConnection(with error: Error?)
}

extension TunnelController {
    public func reportSnapshot(_ snapshot: TunnelSnapshot) {
    }

    public func clearTunnelSettings() async {
        await clearTunnelSettings(withKillSwitch: false)
    }
}

/// Common options to give to ``TunnelController``.
public struct TunnelControllerOptions: Codable, Sendable {
    public var dnsFallbackServers: [String] = []
    public var logsSnapshots: Bool = false

    public init() {}
}
