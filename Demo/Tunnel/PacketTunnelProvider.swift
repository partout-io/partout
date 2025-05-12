//
//  PacketTunnelProvider.swift
//  Partout
//
//  Created by Davide De Rosa on 2/24/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

@preconcurrency import NetworkExtension
import Partout

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var fwd: NEPTPForwarder?

    override init() {
        PartoutConfiguration.shared.logsModules = true
        PartoutConfiguration.shared.setLocalLogger(
            url: Demo.Log.tunnelURL,
            options: .init(
                maxLevel: Demo.Log.maxLevel,
                maxSize: Demo.Log.maxSize,
                maxBufferedLines: Demo.Log.maxBufferedLines
            ),
            mapper: Demo.Log.formattedLine
        )
        super.init()
    }

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        do {
            fwd = try await NEPTPForwarder(
                provider: self,
                decoder: .shared,
                registry: .shared,
                environmentFactory: { _ in
                    Demo.tunnelEnvironment
                }
            )
            try await fwd?.startTunnel(options: options)
        } catch {
            flushLog()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await fwd?.stopTunnel(with: reason)
        fwd = nil
        flushLog()
    }

    override func cancelTunnelWithError(_ error: Error?) {
        flushLog()
        super.cancelTunnelWithError(error)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        await fwd?.handleAppMessage(messageData)
    }

    override func wake() {
        fwd?.wake()
    }

    override func sleep() async {
        await fwd?.sleep()
    }
}

private extension PacketTunnelProvider {
    func flushLog() {
        PartoutConfiguration.shared.flushLog()
        Task {
            try? await Task.sleep(milliseconds: Demo.Log.saveInterval)
            flushLog()
        }
    }
}
