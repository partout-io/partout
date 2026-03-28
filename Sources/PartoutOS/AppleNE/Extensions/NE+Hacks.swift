// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NEPacketTunnelProvider {
    func removeVPNStatusIcon() {
        // XXX: We want to remove the VPN status icon on iOS/tvOS
        // and calling .setTunnelNetworkSettings(nil) doesn't seem
        // to do it. Feeding fake IPv4 settings does the trick.
        let fake = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: NEPacketTunnelNetworkSettings.fakeRemoteAddress
        )
        // XXX: This is to speed up tunnel stop, like in Profile+NE
        fake.ipv4Settings = .fakeLoopbackIP
        setTunnelNetworkSettings(fake)
    }
}

extension NEPacketTunnelNetworkSettings {
    static let fakeRemoteAddress = "127.0.0.1"
}

extension NEIPv4Settings {
    static var fakeLoopbackIP: NEIPv4Settings {
        NEIPv4Settings(
            addresses: ["127.0.0.1"],
            subnetMasks: ["255.255.255.255"]
        )
    }
}
