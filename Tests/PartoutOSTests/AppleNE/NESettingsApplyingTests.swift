// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
import PartoutCore
import PartoutOS
import Testing

struct NESettingsApplyingTests {
    @Test
    func givenIPv4_whenApply_thenUpdatesSettings() throws {
        let ipv4 = IPSettings(subnet: Subnet(rawValue: "2.2.2.2/12")!)
            .including(routes: [
                Route(defaultWithGateway: Address(rawValue: "30.30.30.30")!),
                Route(Subnet(rawValue: "6.6.6.6/8")!, Address(rawValue: "60.60.60.60")!)
            ])
            .excluding(routes: [
                Route(Subnet(rawValue: "7.7.7.7/16")!, Address(rawValue: "70.70.70.70")!),
                Route(Subnet(rawValue: "8.8.8.8/24")!, Address(rawValue: "80.80.80.80")!)
            ])
        let module = IPModule.Builder(ipv4: ipv4).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let settings = try #require(sut.ipv4Settings)
        let subnets = ipv4.subnets
        #expect(settings.addresses == subnets.map(\.address.rawValue))
        #expect(settings.subnetMasks == subnets.map(\.ipv4Mask))
        #expect(settings.includedRoutes?.count == ipv4.includedRoutes.count)
        #expect(settings.excludedRoutes?.count == ipv4.excludedRoutes.count)

        try settings.includedRoutes?.forEach { neRoute in
            let route = try #require(ipv4.includedRoutes.findIPv4Route(neRoute))
            assertMatching(neRoute, route: route)
        }
        try settings.excludedRoutes?.forEach { neRoute in
            let route = try #require(ipv4.excludedRoutes.findIPv4Route(neRoute))
            assertMatching(neRoute, route: route)
        }
    }

    @Test
    func givenIPv6_whenApply_thenUpdatesSettings() throws {
        let ipv6 = IPSettings(subnet: Subnet(rawValue: "::2/96")!)
            .including(routes: [
                Route(defaultWithGateway: Address(rawValue: "::3")!),
                Route(Subnet(rawValue: "::6/24")!, Address(rawValue: "::60")!)
            ])
            .excluding(routes: [
                Route(Subnet(rawValue: "::7/64")!, Address(rawValue: "::70")!),
                Route(Subnet(rawValue: "::8/80")!, Address(rawValue: "::80")!)
            ])
        let module = IPModule.Builder(ipv6: ipv6).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let settings = try #require(sut.ipv6Settings)
        let subnets = ipv6.subnets
        #expect(settings.addresses == subnets.map(\.address.rawValue))
        #expect(settings.networkPrefixLengths.map(\.intValue) == subnets.map(\.prefixLength))
        #expect(settings.includedRoutes?.count == ipv6.includedRoutes.count)
        #expect(settings.excludedRoutes?.count == ipv6.excludedRoutes.count)

        try settings.includedRoutes?.forEach { neRoute in
            let route = try #require(ipv6.includedRoutes.findIPv6Route(neRoute))
            assertMatching(neRoute, route: route)
        }
        try settings.excludedRoutes?.forEach { neRoute in
            let route = try #require(ipv6.excludedRoutes.findIPv6Route(neRoute))
            assertMatching(neRoute, route: route)
        }
    }

    @Test
    func givenHTTPProxy_whenApply_thenUpdatesSettings() throws {
        let module = try HTTPProxyModule.Builder(
            address: "4.5.6.7",
            port: 1080,
            secureAddress: "4.5.6.7",
            securePort: 8080,
            pacURLString: "http://proxy.pac",
            bypassDomains: ["one.com", "two.com"]
        ).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let proxySettings = try #require(sut.proxySettings)
        #expect(proxySettings.httpEnabled)
        #expect(proxySettings.httpsEnabled)
        #expect(proxySettings.httpServer?.address == module.proxy?.address.rawValue)
        #expect(proxySettings.httpServer?.port == module.proxy.map { Int($0.port) })
        #expect(proxySettings.httpsServer?.address == module.secureProxy?.address.rawValue)
        #expect(proxySettings.httpsServer?.port == module.secureProxy.map { Int($0.port) })
        #expect(proxySettings.autoProxyConfigurationEnabled)
        #expect(proxySettings.proxyAutoConfigurationURL == module.pacURL)
        #expect(proxySettings.exceptionList == module.bypassDomains.map(\.rawValue))
    }

    @Test
    func givenDNS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .cleartext,
            servers: ["1.1.1.1", "2.2.2.2"],
            domainName: "domain.com",
            searchDomains: ["one.com", "two.com"]
        ).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try #require(sut.dnsSettings)
        #expect(dnsSettings.dnsProtocol == .cleartext)
        #expect(dnsSettings.servers == module.servers.map(\.rawValue))
        #expect(dnsSettings.domainName == module.domainName?.rawValue)
        #expect(dnsSettings.searchDomains == module.searchDomains?.map(\.rawValue))
    }

    @Test
    func givenDNSOverHTTPS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .https,
            servers: ["1.1.1.1", "2.2.2.2"],
            dohURL: "https://1.1.1.1/dns-query"
        ).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try #require(sut.dnsSettings as? NEDNSOverHTTPSSettings)
        #expect(dnsSettings.dnsProtocol == .HTTPS)
        #expect(dnsSettings.servers == module.servers.map(\.rawValue))
        guard case .https(let url) = module.protocolType else {
            #expect(Bool(false), "Wrong protocolType")
            return
        }
        #expect(dnsSettings.serverURL == url)
    }

    @Test
    func givenDNSOverTLS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.1.1.1", "2.2.2.2"],
            dotHostname: "domain.com"
        ).build()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try #require(sut.dnsSettings as? NEDNSOverTLSSettings)
        #expect(dnsSettings.dnsProtocol == .TLS)
        #expect(dnsSettings.servers == module.servers.map(\.rawValue))
        guard case .tls(let hostname) = module.protocolType else {
            #expect(Bool(false), "Wrong protocolType")
            return
        }
        #expect(dnsSettings.serverName == hostname)
    }

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

// MARK: - Helpers

private extension NESettingsApplyingTests {
    func assertMatching(_ neRoute: NEIPv4Route, route: Route) {
        if let destination = route.destination {
            #expect(neRoute.destinationAddress == destination.address.rawValue)
            #expect(neRoute.destinationSubnetMask == destination.ipv4Mask)
        } else {
            #expect(neRoute.hasSameDestination(as: .default()))
        }
        #expect(neRoute.gatewayAddress == route.gateway?.rawValue)
    }

    func assertMatching(_ neRoute: NEIPv6Route, route: Route) {
        if let destination = route.destination {
            #expect(neRoute.destinationAddress == destination.address.rawValue)
            #expect(neRoute.destinationNetworkPrefixLength.intValue == destination.prefixLength)
        } else {
            #expect(neRoute.hasSameDestination(as: .default()))
        }
        #expect(neRoute.gatewayAddress == route.gateway?.rawValue)
    }
}

private extension Collection where Element == Route {
    func findIPv4Route(_ neRoute: NEIPv4Route) -> Route? {
        first {
            if let destination = $0.destination {
                neRoute.destinationAddress == destination.address.rawValue &&
                neRoute.destinationSubnetMask == destination.ipv4Mask
            } else {
                neRoute.hasSameDestination(as: .default())
            }
        }
    }

    func findIPv6Route(_ neRoute: NEIPv6Route) -> Route? {
        first {
            if let destination = $0.destination {
                neRoute.destinationAddress == destination.address.rawValue &&
                neRoute.destinationNetworkPrefixLength.intValue == destination.prefixLength
            } else {
                neRoute.hasSameDestination(as: .default())
            }
        }
    }
}
