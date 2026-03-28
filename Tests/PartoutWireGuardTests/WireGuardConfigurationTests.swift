// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuardConnection
import Testing

struct WireGuardConfigurationTests {
    @Test
    func givenIpRoutesAndVpnDns_whenApplyingProfileModules_thenKeepsAllAllowedIPs() throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var configurationBuilder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        var peerBuilder = WireGuard.RemoteInterface.Builder(publicKey: pubkey)
        peerBuilder.allowedIPs = ["192.168.0.0/16"]
        configurationBuilder.peers = [peerBuilder]

        let ipSettings = IPSettings(subnet: try Subnet("10.10.10.2", 24))
            .including(routes: [Route(try Subnet("10.20.0.0", 16), nil)])
        let ipModule = IPModule.Builder(ipv4: ipSettings).build()
        let dnsModule = try DNSModule.Builder(
            servers: ["1.1.1.1", "2606:4700:4700::1111"],
            routesThroughVPN: true
        ).build()
        let profile = try Profile.Builder(
            name: "WG",
            modules: [ipModule, dnsModule]
        ).build()

        let cfg = try configurationBuilder.build()
        let mergedConfiguration = try cfg.withModules(from: profile)
        let allowedIPs = mergedConfiguration.peers[0].allowedIPs.map(\.rawValue)
        let mergedConfigurationV2 = try cfg.withModulesV2(from: profile)
        let allowedIPsV2 = mergedConfigurationV2.peers[0].allowedIPs.map(\.rawValue)

        let expectedAllowedIPs = [
            "192.168.0.0/16",
            "10.20.0.0/16",
            "1.1.1.1/32",
            "2606:4700:4700::1111/128"
        ]
        #expect(allowedIPs != expectedAllowedIPs)
        #expect(allowedIPsV2 == expectedAllowedIPs)
    }
}
