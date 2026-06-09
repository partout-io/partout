// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Abstracts tunnel configuration.
public protocol TunnelController: AnyObject, Sendable {
    func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface

    func configureSockets(with descriptors: [FileDescriptor]) throws

    func reportSnapshot(_ snapshot: TunnelSnapshot)

    func clearTunnelSettings(_ tunnel: IOInterface, withKillSwitch: Bool) async

    func setReasserting(_ reasserting: Bool)

    func cancelTunnelConnection(with error: Error?)
}

extension TunnelController {
    public func reportSnapshot(_ snapshot: TunnelSnapshot) {
    }

    public func clearTunnelSettings(_ tunnel: IOInterface) async {
        await clearTunnelSettings(tunnel, withKillSwitch: false)
    }
}
