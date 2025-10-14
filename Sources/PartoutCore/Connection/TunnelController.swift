// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Abstracts tunnel configuration.
public protocol TunnelController: AnyObject, Sendable {
    func setTunnelSettings(with info: TunnelRemoteInfo?) async throws -> IOInterface

    func configureSockets(with descriptors: [UInt64])

    func clearTunnelSettings(_ tunnel: IOInterface) async

    func setReasserting(_ reasserting: Bool)

    func cancelTunnelConnection(with error: Error?)
}
