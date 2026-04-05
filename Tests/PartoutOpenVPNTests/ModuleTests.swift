// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct ModuleTests {
    @Test
    func givenModule_whenSerialize_thenProducesOvpnConfig() throws {
        let caPEM = """
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
"""
        let clientPEM = """
-----BEGIN CERTIFICATE-----
MIIC
-----END CERTIFICATE-----
"""
        let keyPEM = """
-----BEGIN PRIVATE KEY-----
MIIE
-----END PRIVATE KEY-----
"""

        var builder = OpenVPNModule.Builder()
        var configuration = OpenVPN.Configuration.Builder()
        configuration.cipher = .aes256cbc
        configuration.digest = .sha256
        configuration.ca = OpenVPN.CryptoContainer(pem: caPEM)
        configuration.clientCertificate = OpenVPN.CryptoContainer(pem: clientPEM)
        configuration.clientKey = OpenVPN.CryptoContainer(pem: keyPEM)
        configuration.remotes = [
            try ExtendedEndpoint("vpn.example.com", .init(.udp, 1194)),
            try ExtendedEndpoint("vpn.example.com", .init(.tcp4, 443))
        ]
        configuration.authUserPass = true
        configuration.checksEKU = true
        configuration.checksSANHost = true
        configuration.sanHost = "vpn.example.com"
        configuration.randomizeEndpoint = true
        configuration.randomizeHostnames = true
        configuration.mtu = 1400
        configuration.keepAliveInterval = 15
        configuration.keepAliveTimeout = 60
        configuration.routeGateway4 = Address(rawValue: "10.8.0.1")
        configuration.routeGateway6 = Address(rawValue: "2001:db8::1")
        configuration.routingPolicies = [.IPv4, .blockLocal]
        configuration.dnsServers = ["1.1.1.1", "8.8.8.8"]
        configuration.dnsDomain = "example.org"
        configuration.searchDomains = ["example.org", "vpn.example.org"]
        configuration.httpProxy = try Endpoint("192.0.2.1", 8080)
        configuration.httpsProxy = try Endpoint("192.0.2.2", 8443)
        configuration.proxyAutoConfigurationURL = URL(string: "https://pac.example.org/proxy.pac")
        configuration.proxyBypassDomains = ["localhost", "internal.example.org"]
        configuration.xorMethod = .xorptrpos
        configuration.tlsWrap = OpenVPN.TLSWrap(
            strategy: .auth,
            key: OpenVPN.StaticKey(
                data: Data((0..<256).map { UInt8($0) }),
                direction: .client
            )
        )

        builder.configurationBuilder = configuration

        let module = try builder.build()
        let serialized = try module.serialized()
        #expect(serialized.contains("tls-auth [inline]"))
        #expect(serialized.contains("verify-x509-name vpn.example.com name"))
        #expect(serialized.contains("route-gateway 10.8.0.1"))
        #expect(serialized.contains("route-ipv6-gateway 2001:db8::1"))
        let parsed = try StandardOpenVPNParser(decrypter: nil).parsed(fromContents: serialized).configuration

        #expect(parsed.cipher == .aes256cbc)
        #expect(parsed.digest == .sha256)
        #expect(parsed.ca?.pem == caPEM)
        #expect(parsed.clientCertificate?.pem == clientPEM)
        #expect(parsed.clientKey?.pem == keyPEM)
        #expect(parsed.remotes == [
            try ExtendedEndpoint("vpn.example.com", .init(.udp, 1194)),
            try ExtendedEndpoint("vpn.example.com", .init(.tcp4, 443))
        ])
        #expect(parsed.authUserPass == true)
        #expect(parsed.checksEKU == true)
//        #expect(parsed.checksSANHost == true)
//        #expect(parsed.sanHost == "vpn.example.com")
        #expect(parsed.randomizeEndpoint == true)
        #expect(parsed.randomizeHostnames == true)
        #expect(parsed.mtu == 1400)
        #expect(parsed.keepAliveInterval == 15)
        #expect(parsed.keepAliveTimeout == 60)
        #expect(parsed.routeGateway4?.rawValue == "10.8.0.1")
        #expect(parsed.routeGateway6?.rawValue == "2001:db8::1")
        #expect(Set(parsed.routingPolicies ?? []) == Set([.IPv4, .blockLocal]))
        #expect(parsed.dnsServers == ["1.1.1.1", "8.8.8.8"])
        #expect(parsed.dnsDomain == "example.org")
        #expect(parsed.searchDomains == ["example.org", "vpn.example.org"])
        #expect(parsed.httpProxy?.rawValue == "192.0.2.1:8080")
        #expect(parsed.httpsProxy?.rawValue == "192.0.2.2:8443")
        #expect(parsed.proxyAutoConfigurationURL?.absoluteString == "https://pac.example.org/proxy.pac")
        #expect(parsed.proxyBypassDomains == ["localhost", "internal.example.org"])
        #expect(parsed.xorMethod == .xorptrpos)
        #expect(parsed.tlsWrap?.strategy == .auth)
        #expect(parsed.tlsWrap?.key.direction == .client)
    }

    @Test
    func givenModuleWithStaticChallenge_whenSerialize_thenFails() throws {
        var builder = OpenVPNModule.Builder()
        var configuration = OpenVPN.Configuration.Builder()
        configuration.ca = OpenVPN.CryptoContainer(pem: """
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
""")
        configuration.remotes = [
            try ExtendedEndpoint("vpn.example.com", .init(.udp, 1194))
        ]
        builder.configurationBuilder = configuration
        builder.isInteractive = true

        let module = try builder.build()
        #expect(throws: Error.self) {
            try module.serialized()
        }
    }
}
