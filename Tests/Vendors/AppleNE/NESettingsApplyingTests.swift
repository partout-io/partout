//
//  NESettingsApplyingTests.swift
//  Partout
//
//  Created by Davide De Rosa on 3/3/24.
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

import _PartoutVendorsAppleNE
import Foundation
import NetworkExtension
import PartoutCore
import XCTest

final class NESettingsApplyingTests: XCTestCase {
    func test_givenIPv4_whenApply_thenUpdatesSettings() throws {
        let ipv4 = IPSettings(subnet: Subnet(rawValue: "2.2.2.2/12")!)
            .including(routes: [
                Route(defaultWithGateway: Address(rawValue: "30.30.30.30")!),
                Route(Subnet(rawValue: "6.6.6.6/8")!, Address(rawValue: "60.60.60.60")!)
            ])
            .excluding(routes: [
                Route(Subnet(rawValue: "7.7.7.7/16")!, Address(rawValue: "70.70.70.70")!),
                Route(Subnet(rawValue: "8.8.8.8/24")!, Address(rawValue: "80.80.80.80")!)
            ])
        let module = IPModule.Builder(ipv4: ipv4).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let settings = try XCTUnwrap(sut.ipv4Settings)
        let subnets = ipv4.subnet.map { [$0] } ?? []
        XCTAssertEqual(settings.addresses, subnets.map(\.address.rawValue))
        XCTAssertEqual(settings.subnetMasks, subnets.map(\.ipv4Mask))
        XCTAssertEqual(settings.includedRoutes?.count, ipv4.includedRoutes.count)
        XCTAssertEqual(settings.excludedRoutes?.count, ipv4.excludedRoutes.count)

        settings.includedRoutes?.forEach { neRoute in
            guard let route = ipv4.includedRoutes.findIPv4Route(neRoute) else {
                XCTFail("Included route not found: \(neRoute.destinationAddress)")
                return
            }
            assertMatching(neRoute, route: route)
        }
        settings.excludedRoutes?.forEach { neRoute in
            guard let route = ipv4.excludedRoutes.findIPv4Route(neRoute) else {
                XCTFail("Excluded route not found: \(neRoute.destinationAddress)")
                return
            }
            assertMatching(neRoute, route: route)
        }
    }

    func test_givenIPv6_whenApply_thenUpdatesSettings() throws {
        let ipv6 = IPSettings(subnet: Subnet(rawValue: "::2/96")!)
            .including(routes: [
                Route(defaultWithGateway: Address(rawValue: "::3")!),
                Route(Subnet(rawValue: "::6/24")!, Address(rawValue: "::60")!)
            ])
            .excluding(routes: [
                Route(Subnet(rawValue: "::7/64")!, Address(rawValue: "::70")!),
                Route(Subnet(rawValue: "::8/80")!, Address(rawValue: "::80")!)
            ])
        let module = IPModule.Builder(ipv6: ipv6).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let settings = try XCTUnwrap(sut.ipv6Settings)
        let subnets = ipv6.subnet.map { [$0] } ?? []
        XCTAssertEqual(settings.addresses, subnets.map(\.address.rawValue))
        XCTAssertEqual(settings.networkPrefixLengths.map(\.intValue), subnets.map(\.prefixLength))
        XCTAssertEqual(settings.includedRoutes?.count, ipv6.includedRoutes.count)
        XCTAssertEqual(settings.excludedRoutes?.count, ipv6.excludedRoutes.count)

        settings.includedRoutes?.forEach { neRoute in
            guard let route = ipv6.includedRoutes.findIPv6Route(neRoute) else {
                XCTFail("Included route not found: \(neRoute.destinationAddress)")
                return
            }
            assertMatching(neRoute, route: route)
        }
        settings.excludedRoutes?.forEach { neRoute in
            guard let route = ipv6.excludedRoutes.findIPv6Route(neRoute) else {
                XCTFail("Excluded route not found: \(neRoute.destinationAddress)")
                return
            }
            assertMatching(neRoute, route: route)
        }
    }

    func test_givenHTTPProxy_whenApply_thenUpdatesSettings() throws {
        let module = try HTTPProxyModule.Builder(
            address: "4.5.6.7",
            port: 1080,
            secureAddress: "4.5.6.7",
            securePort: 8080,
            pacURLString: "http://proxy.pac",
            bypassDomains: ["one.com", "two.com"]
        ).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let proxySettings = try XCTUnwrap(sut.proxySettings)
        XCTAssertTrue(proxySettings.httpEnabled)
        XCTAssertTrue(proxySettings.httpsEnabled)
        XCTAssertEqual(proxySettings.httpServer?.address, module.proxy?.address.rawValue)
        XCTAssertEqual(proxySettings.httpServer?.port, module.proxy.map { Int($0.port) })
        XCTAssertEqual(proxySettings.httpsServer?.address, module.secureProxy?.address.rawValue)
        XCTAssertEqual(proxySettings.httpsServer?.port, module.secureProxy.map { Int($0.port) })
        XCTAssertTrue(proxySettings.autoProxyConfigurationEnabled)
        XCTAssertEqual(proxySettings.proxyAutoConfigurationURL, module.pacURL)
        XCTAssertEqual(proxySettings.exceptionList, module.bypassDomains.map(\.rawValue))
    }

    func test_givenDNS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .cleartext,
            servers: ["1.1.1.1", "2.2.2.2"],
            domainName: "domain.com",
            searchDomains: ["one.com", "two.com"]
        ).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try XCTUnwrap(sut.dnsSettings)
        XCTAssertEqual(dnsSettings.dnsProtocol, .cleartext)
        XCTAssertEqual(dnsSettings.servers, module.servers.map(\.rawValue))
        XCTAssertEqual(dnsSettings.domainName, module.domainName?.rawValue)
        XCTAssertEqual(dnsSettings.searchDomains, module.searchDomains?.map(\.rawValue))
    }

    func test_givenDNSOverHTTPS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .https,
            servers: ["1.1.1.1", "2.2.2.2"],
            dohURL: "https://1.1.1.1/dns-query"
        ).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try XCTUnwrap(sut.dnsSettings as? NEDNSOverHTTPSSettings)
        XCTAssertEqual(dnsSettings.dnsProtocol, .HTTPS)
        XCTAssertEqual(dnsSettings.servers, module.servers.map(\.rawValue))
        guard case .https(let url) = module.protocolType else {
            XCTFail("Wrong protocolType")
            return
        }
        XCTAssertEqual(dnsSettings.serverURL, url)
    }

    func test_givenDNSOverTLS_whenApply_thenUpdatesSettings() throws {
        let module = try DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.1.1.1", "2.2.2.2"],
            dotHostname: "domain.com"
        ).tryBuild()

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        let dnsSettings = try XCTUnwrap(sut.dnsSettings as? NEDNSOverTLSSettings)
        XCTAssertEqual(dnsSettings.dnsProtocol, .TLS)
        XCTAssertEqual(dnsSettings.servers, module.servers.map(\.rawValue))
        guard case .tls(let hostname) = module.protocolType else {
            XCTFail("Wrong protocolType")
            return
        }
        XCTAssertEqual(dnsSettings.serverName, hostname)
    }

    func test_givenNESettings_whenApply_thenReplacesSettings() throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "1.2.3.4")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["6.6.6.6"], subnetMasks: ["255.0.0.0"])
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        settings.proxySettings = NEProxySettings()
        settings.proxySettings?.proxyAutoConfigurationURL = URL(string: "hello.com")!
        settings.mtu = 1200
        let module = NESettingsModule(fullSettings: settings)

        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "")
        module.apply(.global, to: &sut)

        XCTAssertEqual(sut, settings)
    }

    func test_givenNESettings_whenApplyFilter_thenDisablesSettings() throws {
        var sut = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "1.2.3.4")
        sut.ipv4Settings = NEIPv4Settings(addresses: ["6.6.6.6"], subnetMasks: ["255.0.0.0"])
        sut.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        sut.proxySettings = NEProxySettings()
        sut.proxySettings?.proxyAutoConfigurationURL = URL(string: "hello.com")!
        sut.mtu = 1200

        let filterModule = FilterModule.Builder(
            disabledMask: [.ipv4, .ipv6, .dns, .proxy, .mtu]
        ).tryBuild()
        filterModule.apply(.global, to: &sut)
        XCTAssertNil(sut.ipv4Settings)
        XCTAssertNil(sut.ipv6Settings)
        XCTAssertNil(sut.dnsSettings)
        XCTAssertNil(sut.proxySettings)
        XCTAssertNil(sut.mtu)
        XCTAssertNil(sut.tunnelOverheadBytes)
    }
}

// MARK: - Helpers

private extension NESettingsApplyingTests {
    func assertMatching(_ neRoute: NEIPv4Route, route: Route) {
        if let destination = route.destination {
            XCTAssertEqual(neRoute.destinationAddress, destination.address.rawValue)
            XCTAssertEqual(neRoute.destinationSubnetMask, destination.ipv4Mask)
        } else {
            XCTAssertEqual(neRoute, NEIPv4Route.default())
        }
        XCTAssertEqual(neRoute.gatewayAddress, route.gateway?.rawValue)
    }

    func assertMatching(_ neRoute: NEIPv6Route, route: Route) {
        if let destination = route.destination {
            XCTAssertEqual(neRoute.destinationAddress, destination.address.rawValue)
            XCTAssertEqual(neRoute.destinationNetworkPrefixLength.intValue, destination.prefixLength)
        } else {
            XCTAssertEqual(neRoute, NEIPv6Route.default())
        }
        XCTAssertEqual(neRoute.gatewayAddress, route.gateway?.rawValue)
    }
}

private extension Collection where Element == Route {
    func findIPv4Route(_ neRoute: NEIPv4Route) -> Route? {
        first {
            if let destination = $0.destination {
                neRoute.destinationAddress == destination.address.rawValue &&
                neRoute.destinationSubnetMask == destination.ipv4Mask
            } else {
                neRoute == NEIPv4Route.default()
            }
        }
    }

    func findIPv6Route(_ neRoute: NEIPv6Route) -> Route? {
        first {
            if let destination = $0.destination {
                neRoute.destinationAddress == destination.address.rawValue &&
                neRoute.destinationNetworkPrefixLength.intValue == destination.prefixLength
            } else {
                neRoute == NEIPv6Route.default()
            }
        }
    }
}
