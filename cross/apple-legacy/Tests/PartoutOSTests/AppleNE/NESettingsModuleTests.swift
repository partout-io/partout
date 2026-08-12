// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
import PartoutLegacyCore
import PartoutOS
import Testing

struct NESettingsModuleTests {
    @Test
    func givenNESettings_whenApply_thenReplacesSettings() throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "1.2.3.4")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["6.6.6.6"], subnetMasks: ["255.0.0.0"])
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        settings.proxySettings = NEProxySettings()
        settings.proxySettings?.proxyAutoConfigurationURL = URL(string: "hello.com")!
        settings.mtu = 1200
        let module = NESettingsModule(fullSettings: settings)

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        #expect(sut == settings)
    }
}
