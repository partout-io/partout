// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuardConnection
import Testing

struct WireGuardAdapterTests {
    @Test(arguments: [
        (["1.2.3.4", "22:4", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["22:4", "1.2.3.4", "55:3:4::9f"], "1.2.3.4", "22:4"),
        (["1.2.3.4", "5.6.7.8", "55:3:4::9f"], "1.2.3.4", "1.2.3.4"),
        (["1:2:3::4", "22:4", "55:3:4::9f"], "1:2:3::4", "1:2:3::4")
    ])
    func givenEndpoints_thenPrefersIPv4(
        endpoints: [String],
        targetIPv4: String,
        targetAny: String
    ) async throws {
        let sourceEndpoint = try Endpoint("foobar.com", 1080)
        let endpointObjects = try endpoints.map {
            try Endpoint($0, sourceEndpoint.port)
        }
        let targetIPv4Object = try Endpoint(targetIPv4, sourceEndpoint.port)

        let withEnabled = WireGuard.Configuration.ResolvedMap()
        await withEnabled.setEndpoints(endpointObjects, for: sourceEndpoint)
        let enabledMap = await withEnabled.toMap()
        #expect(enabledMap[sourceEndpoint] == targetIPv4Object)
    }

    @Test
    func givenSameHostnameWithDifferentPorts_whenResolved_thenKeepsBothPeers() async throws {
        let sourceEndpoint1 = try Endpoint("foobar.com", 1080)
        let sourceEndpoint2 = try Endpoint("foobar.com", 2080)
        let resolvedEndpoint1 = try Endpoint("1.2.3.4", sourceEndpoint1.port)
        let resolvedEndpoint2 = try Endpoint("5.6.7.8", sourceEndpoint2.port)

        let withEnabled = WireGuard.Configuration.ResolvedMap()
        await withEnabled.setEndpoints([resolvedEndpoint1], for: sourceEndpoint1)
        await withEnabled.setEndpoints([resolvedEndpoint2], for: sourceEndpoint2)
        let enabledMap = await withEnabled.toMap()

        #expect(enabledMap[sourceEndpoint1] == resolvedEndpoint1)
        #expect(enabledMap[sourceEndpoint2] == resolvedEndpoint2)
    }

    @Test
    func givenInterfaceAddresses_whenGeneratingRemoteInfo_thenMasksInterfaceRoutes() throws {
        let pvtkey = "SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs="
        let pubkey = "BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw="

        var builder = WireGuard.Configuration.Builder(privateKey: pvtkey)
        builder.interface.addresses = [
            "10.0.0.2/24",
            "fd00::2/64"
        ]
        builder.peers = [.init(publicKey: pubkey)]

        let configuration = try builder.build()
        let sut = TunnelRemoteInfoGenerator(
            .global,
            tunnelConfiguration: configuration,
            dnsTimeout: 1
        )
        let info = sut.generateRemoteInfo(moduleId: UniqueID(), descriptors: [])
        let ipModule = try #require(info.modules?.compactMap {
            $0 as? IPModule
        }.first)

        #expect(ipModule.ipv4?.includedRoutes.first?.destination?.rawValue == "10.0.0.0/24")
        #expect(ipModule.ipv4?.includedRoutes.first?.gateway?.rawValue == "10.0.0.2")
        #expect(ipModule.ipv6?.includedRoutes.first?.destination?.rawValue == "fd00::/64")
        #expect(ipModule.ipv6?.includedRoutes.first?.gateway?.rawValue == "fd00::2")
    }

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

        let mergedConfiguration = try configurationBuilder.build().withModules(from: profile)
        let allowedIPs = mergedConfiguration.peers[0].allowedIPs.map { $0.rawValue }

        #expect(allowedIPs == [
            "192.168.0.0/16",
            "10.20.0.0/16",
            "1.1.1.1/32",
            "2606:4700:4700::1111/128"
        ])
    }
}
