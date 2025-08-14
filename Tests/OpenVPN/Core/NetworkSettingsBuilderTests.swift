// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutOpenVPN
import Foundation
import PartoutCore
import Testing

struct NetworkSettingsBuilderTests {

    // MARK: IP

    @Test
    func givenSettings_whenBuildIPModule_thenRequiresRemoteIP() throws {
        var remoteOptions = OpenVPN.Configuration.Builder()

        remoteOptions.ipv4 = nil
        remoteOptions.ipv6 = nil
        #expect(try builtModule(ofType: IPModule.self, with: remoteOptions) == nil)
        remoteOptions.ipv4 = IPSettings(subnet: Subnet(rawValue: "100.1.2.3/32")!)
        #expect(try builtModule(ofType: IPModule.self, with: remoteOptions) != nil)

        remoteOptions.ipv4 = nil
        remoteOptions.ipv6 = nil
        #expect(try builtModule(ofType: IPModule.self, with: remoteOptions) == nil)
        remoteOptions.ipv6 = IPSettings(subnet: Subnet(rawValue: "100:1:2::3/32")!)
        #expect(try builtModule(ofType: IPModule.self, with: remoteOptions) != nil)
    }

    @Test
    func givenSettings_whenBuildIPModule_thenMergesRoutes() throws {
        var sut: IPModule
        let allRoutes4 = [
            Route(Subnet(rawValue: "1.1.1.1/16")!, nil),
            Route(Subnet(rawValue: "2.2.2.2/8")!, nil),
            Route(Subnet(rawValue: "3.3.3.3/24")!, nil),
            Route(Subnet(rawValue: "4.4.4.4/32")!, nil)
        ]
        let allRoutes6 = [
            Route(Subnet(rawValue: "::1/16")!, nil),
            Route(Subnet(rawValue: "::2/8")!, nil),
            Route(Subnet(rawValue: "::3/24")!, nil),
            Route(Subnet(rawValue: "::4/32")!, nil)
        ]
        let localRoutes4 = Array(allRoutes4.prefix(2))
        let localRoutes6 = Array(allRoutes6.prefix(2))
        let remoteRoutes4 = Array(allRoutes4.suffix(from: 2))
        let remoteRoutes6 = Array(allRoutes6.suffix(from: 2))

        var localOptions = OpenVPN.Configuration.Builder()
        localOptions.routes4 = localRoutes4
        localOptions.routes6 = localRoutes6
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.ipv4 = IPSettings(subnet: Subnet(rawValue: "100.1.2.3/32")!)
        remoteOptions.ipv6 = IPSettings(subnet: Subnet(rawValue: "100:1:2::3/32")!)
        remoteOptions.routes4 = remoteRoutes4
        remoteOptions.routes6 = remoteRoutes6

        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.ipv4?.includedRoutes == allRoutes4)
        #expect(sut.ipv6?.includedRoutes == allRoutes6)

        localOptions.noPullMask = [.routes]
        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.ipv4?.includedRoutes == localOptions.routes4)
        #expect(sut.ipv6?.includedRoutes == localOptions.routes6)
    }

    @Test
    func givenSettings_whenBuildIPModule_thenFollowsRoutingPolicies() throws {
        let routeGw4 = "6.6.6.6"
        let routeGw6 = "::6"

        var sut: IPModule
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.ipv4 = IPSettings(
            subnet: Subnet(try #require(Address(rawValue: "1.1.1.1")), 16)
        )
        remoteOptions.routeGateway4 = Address(rawValue: routeGw4)
        remoteOptions.ipv6 = IPSettings(
            subnet: Subnet(try #require(Address(rawValue: "1:1::1")), 72)
        )
        remoteOptions.routeGateway6 = Address(rawValue: routeGw6)

        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions))
        #expect(sut.ipv4?.subnet?.rawValue == "1.1.1.1/16")
        #expect(sut.ipv6?.subnet?.rawValue == "1:1::1/72")
        #expect(!(sut.ipv4?.includesDefaultRoute ?? false))
        #expect(!(sut.ipv6?.includesDefaultRoute ?? false))

        remoteOptions.routingPolicies = [.IPv4]
        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions))
        #expect(sut.ipv4?.includesDefaultRoute ?? false)
        #expect(sut.ipv4?.defaultRoute?.gateway == remoteOptions.routeGateway4)
        #expect(!(sut.ipv6?.includesDefaultRoute ?? false))

        remoteOptions.routingPolicies = [.IPv6]
        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions))
        #expect(!(sut.ipv4?.includesDefaultRoute ?? false))
        #expect(sut.ipv6?.includesDefaultRoute ?? false)
        #expect(sut.ipv6?.defaultRoute?.gateway == remoteOptions.routeGateway6)

        remoteOptions.routingPolicies = [.IPv4, .IPv6]
        sut = try #require(try builtModule(ofType: IPModule.self, with: remoteOptions))
        #expect(sut.ipv4?.includesDefaultRoute ?? false)
        #expect(sut.ipv6?.includesDefaultRoute ?? false)
        #expect(sut.ipv4?.defaultRoute?.gateway == remoteOptions.routeGateway4)
        #expect(sut.ipv6?.defaultRoute?.gateway == remoteOptions.routeGateway6)
    }

    @Test
    func givenSettings_whenBuildIPModule_thenLocalRoutesUseRemoteGateway() throws {
        let routeGw4 = "6.6.6.6"
        let routeGw6 = "::6"

        var sut: IPModule
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.routingPolicies = [.IPv4, .IPv6]
        remoteOptions.ipv4 = IPSettings(
            subnet: Subnet(try #require(Address(rawValue: "1.1.1.1")), 16)
        )
        remoteOptions.routeGateway4 = Address(rawValue: routeGw4)
        remoteOptions.ipv6 = IPSettings(
            subnet: Subnet(try #require(Address(rawValue: "1:1::1")), 72)
        )
        remoteOptions.routeGateway6 = Address(rawValue: routeGw6)
        var localOptions = OpenVPN.Configuration.Builder()
        localOptions.routes4 = [
            Route(Subnet(rawValue: "50.50.50.50/24"), nil)
        ]
        localOptions.routes6 = [
            Route(Subnet(rawValue: "50:50::50/64"), nil)
        ]

        sut = try #require(try builtModule(
            ofType: IPModule.self,
            with: remoteOptions,
            localOptions: localOptions
        ))
        #expect(sut.ipv4?.subnet?.rawValue == "1.1.1.1/16")
        #expect(sut.ipv6?.subnet?.rawValue == "1:1::1/72")
        #expect(sut.ipv4?.includesDefaultRoute ?? false)
        #expect(sut.ipv6?.includesDefaultRoute ?? false)
        #expect(sut.ipv4?.includedRoutes == [
            Route(Subnet(rawValue: "50.50.50.50/24"), remoteOptions.routeGateway4),
            Route(defaultWithGateway: remoteOptions.routeGateway4)
        ])
        #expect(sut.ipv6?.includedRoutes == [
            Route(Subnet(rawValue: "50:50::50/64"), remoteOptions.routeGateway6),
            Route(defaultWithGateway: remoteOptions.routeGateway6)
        ])

        remoteOptions.routingPolicies = []
        sut = try #require(try builtModule(
            ofType: IPModule.self,
            with: remoteOptions,
            localOptions: localOptions
        ))
        #expect(!(sut.ipv4?.includesDefaultRoute ?? false))
        #expect(!(sut.ipv6?.includesDefaultRoute ?? false))
    }

    // MARK: DNS

    @Test
    func givenSettings_whenBuildDNSModule_thenRequiresServers() throws {
        var localOptions = OpenVPN.Configuration.Builder()
        var remoteOptions = OpenVPN.Configuration.Builder()

        #expect(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions) == nil)

        localOptions.dnsServers = ["1.1.1.1"]
        remoteOptions.dnsServers = nil
        #expect(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.dnsServers = nil
        remoteOptions.dnsServers = ["1.1.1.1"]
        #expect(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.dnsServers = []
        remoteOptions.dnsServers = []
        #expect(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions) == nil)
    }

    @Test
    func givenSettings_whenBuildDNSModule_thenMergesServers() throws {
        var sut: DNSModule
        let allServers = [
            Address(rawValue: "1.1.1.1")!,
            Address(rawValue: "2.2.2.2")!,
            Address(rawValue: "3.3.3.3")!
        ]
        let localServers = Array(allServers.prefix(2))
        let remoteServers = Array(allServers.suffix(from: 2))

        var localOptions = OpenVPN.Configuration.Builder()
        localOptions.dnsServers = localServers.map(\.rawValue)
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.dnsServers = remoteServers.map(\.rawValue)

        sut = try #require(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.servers == allServers)

        localOptions.noPullMask = [.dns]
        sut = try #require(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.servers == localServers)
    }

    @Test
    func givenSettings_whenBuildDNSModule_thenMergesDomains() throws {
        var sut: DNSModule
        let allDomains = [
            Address(rawValue: "one.com")!,
            Address(rawValue: "two.com")!,
            Address(rawValue: "three.com")!
        ]
        let localDomains = Array(allDomains.prefix(2))
        let remoteDomains = Array(allDomains.suffix(from: 2))

        var localOptions = OpenVPN.Configuration.Builder()
        localOptions.dnsServers = ["1.1.1.1"]
        localOptions.searchDomains = localDomains.map(\.rawValue)
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.searchDomains = remoteDomains.map(\.rawValue)

        sut = try #require(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.searchDomains == allDomains)

        localOptions.noPullMask = [.dns]
        sut = try #require(try builtModule(ofType: DNSModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.searchDomains == localDomains)
    }

    // MARK: Proxy

    @Test
    func givenSettings_whenBuildHTTPProxyModule_thenRequiresEndpoint() throws {
        var localOptions = OpenVPN.Configuration.Builder()
        var remoteOptions = OpenVPN.Configuration.Builder()

        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) == nil)

        localOptions.httpProxy = Endpoint(rawValue: "1.1.1.1:8080")!
        remoteOptions.httpProxy = nil
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)
        localOptions.httpsProxy = Endpoint(rawValue: "1.1.1.1:8080")!
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.httpProxy = nil
        remoteOptions.httpProxy = Endpoint(rawValue: "1.1.1.1:8080")!
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)
        remoteOptions.httpsProxy = Endpoint(rawValue: "1.1.1.1:8080")!
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.httpProxy = nil
        remoteOptions.httpProxy = nil
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)
        localOptions.httpsProxy = nil
        remoteOptions.httpsProxy = nil
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) == nil)
    }

    @Test
    func givenSettings_whenBuildACProxyModule_thenRequiresURL() throws {
        var localOptions = OpenVPN.Configuration.Builder()
        var remoteOptions = OpenVPN.Configuration.Builder()

        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) == nil)

        localOptions.proxyAutoConfigurationURL = URL(string: "https://www.gogle.com")!
        remoteOptions.proxyAutoConfigurationURL = nil
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.proxyAutoConfigurationURL = nil
        remoteOptions.proxyAutoConfigurationURL = URL(string: "https://www.gogle.com")!
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) != nil)

        localOptions.proxyAutoConfigurationURL = nil
        remoteOptions.proxyAutoConfigurationURL = nil
        #expect(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions) == nil)
    }

    @Test
    func givenSettings_whenBuildProxyModule_thenMergesBypassDomains() throws {
        var sut: HTTPProxyModule
        let allDomains = [
            Address(rawValue: "one.com")!,
            Address(rawValue: "two.com")!,
            Address(rawValue: "three.com")!
        ]
        let localDomains = Array(allDomains.prefix(2))
        let remoteDomains = Array(allDomains.suffix(from: 2))

        var localOptions = OpenVPN.Configuration.Builder()
        localOptions.httpProxy = Endpoint(rawValue: "1.1.1.1:8080")!
        localOptions.proxyBypassDomains = localDomains.map(\.rawValue)
        var remoteOptions = OpenVPN.Configuration.Builder()
        remoteOptions.proxyBypassDomains = remoteDomains.map(\.rawValue)

        sut = try #require(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.bypassDomains == allDomains)

        localOptions.noPullMask = [.proxy]
        sut = try #require(try builtModule(ofType: HTTPProxyModule.self, with: remoteOptions, localOptions: localOptions))
        #expect(sut.bypassDomains == localDomains)
    }

    // MARK: MTU

    @Test
    func givenSettings_whenBuildMTU_thenReturnsLocalMTU() throws {
        var sut: NetworkSettingsBuilder
        var localOptions = OpenVPN.Configuration.Builder()
        var remoteOptions = OpenVPN.Configuration.Builder()

        localOptions.mtu = 1200
        sut = try newBuilder(with: remoteOptions, localOptions: localOptions)
        #expect((sut.modules().first as? IPModule)?.mtu == localOptions.mtu)

        remoteOptions.mtu = 1400
        sut = try newBuilder(with: remoteOptions, localOptions: localOptions)
        #expect((sut.modules().first as? IPModule)?.mtu == localOptions.mtu)

        localOptions.mtu = nil
        sut = try newBuilder(with: remoteOptions, localOptions: localOptions)
        #expect((sut.modules().first as? IPModule)?.mtu == nil)
    }
}

// MARK: - Helpers

private extension NetworkSettingsBuilderTests {
    func builtModule<T>(
        ofType type: T.Type,
        with remoteOptions: OpenVPN.Configuration.Builder,
        localOptions: OpenVPN.Configuration.Builder? = nil
    ) throws -> T? where T: Module {
        try newBuilder(with: remoteOptions, localOptions: localOptions)
            .modules()
            .first(ofType: type)
    }

    func newBuilder(
        with remoteOptions: OpenVPN.Configuration.Builder,
        localOptions: OpenVPN.Configuration.Builder? = nil
    ) throws -> NetworkSettingsBuilder {
        NetworkSettingsBuilder(
            .global,
            localOptions: try (localOptions ?? OpenVPN.Configuration.Builder()).tryBuild(isClient: false),
            remoteOptions: try remoteOptions.tryBuild(isClient: false)
        )
    }
}
