// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutWireGuard

extension WireGuard.Configuration {
    init(wgQuickConfig: String) throws {
        let wg = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
        try self.init(wg: wg)
    }

    init(wg: TunnelConfiguration) throws {
        let interface = try WireGuard.LocalInterface(wg: wg.interface)
        let peers = try wg.peers.map {
            try WireGuard.RemoteInterface(wg: $0)
        }
        let builder = WireGuard.Configuration.Builder(
            interface: interface.builder(),
            peers: peers.map {
                $0.builder()
            }
        )
        self = try builder.tryBuild()
    }

    func toWireGuardConfiguration() throws -> TunnelConfiguration {
        let wgInterface = try interface.toWireGuardConfiguration()
        let wgPeers = try peers.map {
            try $0.toWireGuardConfiguration()
        }
        return TunnelConfiguration(name: nil, interface: wgInterface, peers: wgPeers)
    }

    func toWgQuickConfig() throws -> String {
        try toWireGuardConfiguration().asWgQuickConfig()
    }
}
