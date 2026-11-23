// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NEPacketTunnelProvider {
    func clearTunnelSettings(withKillSwitch: Bool) async throws {
        // XXX: We want to remove the VPN status icon on iOS/tvOS
        // and calling .setTunnelNetworkSettings(nil) doesn't seem
        // to do it. Feeding fake IPv4 settings does the trick.
        if withKillSwitch {
            let fake = NEPacketTunnelNetworkSettings(
                tunnelRemoteAddress: NEPacketTunnelNetworkSettings.fakeRemoteAddress
            )
            // XXX: This is to speed up tunnel stop, like in Profile+NE
            fake.ipv4Settings = .fakeLoopback
            fake.ipv6Settings = .fakeLoopback
            // Block the Internet
            if withKillSwitch {
                fake.ipv4Settings?.includedRoutes = [.default()]
                fake.ipv6Settings?.includedRoutes = [.default()]
            }
            try await setTunnelNetworkSettings(fake)
            return
        }
        try await setTunnelNetworkSettings(nil)
    }
}

extension NEPacketTunnelNetworkSettings {
    static let fakeRemoteAddress = "127.0.0.1"
}

extension NEIPv4Settings {
    static var fakeLoopback: NEIPv4Settings {
        NEIPv4Settings(
            addresses: ["127.0.0.1"],
            subnetMasks: ["255.255.255.255"]
        )
    }
}

extension NEIPv6Settings {
    static var fakeLoopback: NEIPv6Settings {
        NEIPv6Settings(
            addresses: ["::1"],
            networkPrefixLengths: [128]
        )
    }
}
