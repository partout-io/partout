// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import PartoutOpenVPN
import PartoutCore
import Testing

struct StandardOpenVPNParserTests {
    private let parser = StandardOpenVPNParser(supportsLZO: true, decrypter: nil)

    @Test
    func givenOption_whenEnumerateComponents_thenAreParsedCorrectly() throws {
        let sut = try OpenVPN.Option.remote.regularExpression()
        _ = sut.enumerateSpacedComponents(in: "remote    one.two.com   12345   tcp") {
            #expect($0 == ["remote", "one.two.com", "12345", "tcp"])
        }
    }

    // MARK: Lines

    @Test
    func givenLZO_whenParse_thenIsHandled() throws {
        #expect(try parser.parsed(fromLines: ["comp-lzo"]).warning == nil)
        _ = try parser.parsed(fromLines: ["comp-lzo no"])
        _ = try parser.parsed(fromLines: ["comp-lzo yes"])
        _ = try parser.parsed(fromLines: ["compress"])
        _ = try parser.parsed(fromLines: ["compress lzo"])
    }

    @Test
    func givenKeepAlive_whenParse_thenIsHandled() throws {
        let cfg1 = try parser.parsed(fromLines: ["ping 10", "ping-restart 60"])
        let cfg2 = try parser.parsed(fromLines: ["keepalive 10 60"])
        let cfg3 = try parser.parsed(fromLines: ["keepalive 15 600"])
        #expect(cfg1.configuration.keepAliveInterval == cfg2.configuration.keepAliveInterval)
        #expect(cfg1.configuration.keepAliveTimeout == cfg2.configuration.keepAliveTimeout)
        #expect(cfg1.configuration.keepAliveInterval != cfg3.configuration.keepAliveInterval)
        #expect(cfg1.configuration.keepAliveTimeout != cfg3.configuration.keepAliveTimeout)
    }

    @Test
    func givenDHCPOption_whenParse_thenIsHandled() throws {
        let lines = [
            "dhcp-option DNS 8.8.8.8",
            "dhcp-option DNS6 ffff::1",
            "dhcp-option DOMAIN first-domain.net",
            "dhcp-option DOMAIN second-domain.org",
            "dhcp-option DOMAIN-SEARCH fake-main.net",
            "dhcp-option DOMAIN-SEARCH main.net",
            "dhcp-option DOMAIN-SEARCH one.com",
            "dhcp-option DOMAIN-SEARCH two.com",
            "dhcp-option PROXY_HTTP 1.2.3.4 8081",
            "dhcp-option PROXY_HTTPS 7.8.9.10 8082",
            "dhcp-option PROXY_AUTO_CONFIG_URL https://pac/",
            "dhcp-option PROXY_BYPASS   foo.com   bar.org     net.chat"
        ]
        _ = try parser.parsed(fromLines: lines)

        let parsed = try parser.parsed(fromLines: lines).configuration
        #expect(parsed.dnsServers == ["8.8.8.8", "ffff::1"])
        #expect(parsed.dnsDomain == "second-domain.org")
        #expect(parsed.searchDomains == ["fake-main.net", "main.net", "one.com", "two.com"])
        #expect(parsed.httpProxy?.address.rawValue == "1.2.3.4")
        #expect(parsed.httpProxy?.port == 8081)
        #expect(parsed.httpsProxy?.address.rawValue == "7.8.9.10")
        #expect(parsed.httpsProxy?.port == 8082)
        #expect(parsed.proxyAutoConfigurationURL?.absoluteString == "https://pac/")
        #expect(parsed.proxyBypassDomains == ["foo.com", "bar.org", "net.chat"])
    }

    @Test
    func givenRedirectGateway_whenParse_thenIsHandled() throws {
        let parsed = try parser.parsed(fromLines: ["redirect-gateway   def1   block-local"]).configuration
        let routingPolicies = try #require(parsed.routingPolicies)
        #expect(Set(routingPolicies) == Set([.IPv4, .blockLocal]))
    }

    @Test
    func givenConnectionBlock_whenParse_thenFails() throws {
        let lines = ["<connection>", "</connection>"]
        #expect(throws: Error.self) {
            try parser.parsed(fromLines: lines)
        }
    }

    @Test
    func givenTLSCryptV2_whenParse_thenFails() throws {
        let lines = ["tls-crypt-v2-client"]
        #expect(throws: Error.self) {
            try parser.parsed(fromLines: lines)
        }
    }

    // MARK: URL

    @Test
    func givenPIA_whenParse_thenIsParsedCorrectly() throws {
        let file = try parser.parsed(fromURL: url(withName: "pia-hungary"))

        #expect(file.configuration.remotes == [
            try? ExtendedEndpoint("hungary.privateinternetaccess.com", .init(.udp, 1198)),
            try? ExtendedEndpoint("hungary.privateinternetaccess.com", .init(.tcp, 502))
        ].compactMap { $0 })

        #expect(file.configuration.cipher == .aes128cbc)
        #expect(file.configuration.digest == .sha1)
        #expect(file.configuration.authUserPass == true)
        #expect(file.configuration.compressionAlgorithm == .disabled)
        #expect(file.configuration.renegotiatesAfter == .zero)

        #expect(file.configuration.ca?.pem.hasPrefix("-----BEGIN CERTIFICATE-----") ?? false)
    }

    @Test
    func givenProtonVPN_whenParse_thenIsParsedCorrectly() throws {
        let file = try parser.parsed(fromURL: url(withName: "protonvpn"))

        #expect(file.configuration.remotes == [
            try? ExtendedEndpoint("103.212.227.123", .init(.udp, 5060)),
            try? ExtendedEndpoint("103.212.227.123", .init(.udp, 1194)),
            try? ExtendedEndpoint("103.212.227.123", .init(.udp, 443)),
            try? ExtendedEndpoint("103.212.227.123", .init(.udp, 4569)),
            try? ExtendedEndpoint("103.212.227.123", .init(.udp, 80))
        ].compactMap { $0 })

        #expect(file.configuration.randomizeEndpoint == true)
        #expect(file.configuration.cipher == .aes256cbc)
        #expect(file.configuration.digest == .sha512)
        #expect(file.configuration.renegotiatesAfter == .zero)
        #expect(file.configuration.authUserPass == true)

        let mask = Data("this-is-a-mask".utf8)
        #expect(file.configuration.xorMethod == OpenVPN.ObfuscationMethod.obfuscate(mask: SecureData(mask)))

        #expect(file.configuration.ca?.pem.hasPrefix("-----BEGIN CERTIFICATE-----") ?? false)
        #expect(file.configuration.tlsWrap?.strategy == .auth)
        #expect(file.configuration.tlsWrap?.key.direction == .client)
        #expect(file.configuration.tlsWrap?.key.hexString.hasPrefix("6acef03f62675b4b1bbd03e53b187727") ?? false)
    }

    @Test
    func givenXOR_whenParse_thenIsHandled() throws {
        let asciiData = "F"
        let singleMask = try #require(SecureData(String(repeating: asciiData, count: 1)))
        let multiMask = try #require(SecureData(String(repeating: asciiData, count: 4)))

        let cfg = try parser.parsed(fromLines: ["scramble xormask F"])
        #expect(cfg.warning == nil)
        #expect(cfg.configuration.xorMethod == .xormask(mask: singleMask))

        let cfg2 = try parser.parsed(fromLines: ["scramble reverse"])
        #expect(cfg.warning == nil)
        #expect(cfg2.configuration.xorMethod == .reverse)

        let cfg3 = try parser.parsed(fromLines: ["scramble xorptrpos"])
        #expect(cfg.warning == nil)
        #expect(cfg3.configuration.xorMethod == .xorptrpos)

        let cfg4 = try parser.parsed(fromLines: ["scramble obfuscate FFFF"])
        #expect(cfg.warning == nil)
        #expect(cfg4.configuration.xorMethod == .obfuscate(mask: multiMask))
    }

    // MARK: PKCS

    @Test(arguments: allParsers())
    func givenPKCS1_whenParse_thenFails(sut: StandardOpenVPNParser) {
        let cfgURL = url(withName: "tunnelbear.enc.1")
        do {
            _ = try sut.parsed(fromURL: cfgURL)
            #expect(Bool(false))
        } catch {
            //
        }
    }

    @Test(arguments: allParsers())
    func givenPKCS1_whenParseWithPassphrase_thenSucceeds(sut: StandardOpenVPNParser) throws {
        let cfgURL = url(withName: "tunnelbear.enc.1")
        _ = try sut.parsed(fromURL: cfgURL, passphrase: "foobar")
    }

    @Test(arguments: allParsers())
    func givenPKCS8_whenParse_thenFails(sut: StandardOpenVPNParser) {
        let cfgURL = url(withName: "tunnelbear.enc.8")
        do {
            _ = try sut.parsed(fromURL: cfgURL)
            #expect(Bool(false))
        } catch {
            //
        }
    }

    @Test(arguments: allParsers())
    func givenPKCS8_whenParseWithPassphrase_thenSucceeds(sut: StandardOpenVPNParser) throws {
        let cfgURL = url(withName: "tunnelbear.enc.8")
        do {
            _ = try sut.parsed(fromURL: cfgURL)
            #expect(Bool(false))
        } catch {
            //
        }
        _ = try sut.parsed(fromURL: cfgURL, passphrase: "foobar")
    }
}

// MARK: - Helpers

private extension StandardOpenVPNParserTests {
    func url(withName name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ovpn") else {
            fatalError("Cannot find URL in bundle")
        }
        return url
    }
}

#if canImport(PartoutOpenVPN_ObjC)
import PartoutOpenVPN_ObjC
#endif

private func allParsers() -> [StandardOpenVPNParser] {
#if OPENVPN_DEPRECATED_LZO
    let supportsLZO = true
#else
    let supportsLZO = false
#endif
    var list = [StandardOpenVPNParser(supportsLZO: supportsLZO, decrypter: SimpleKeyDecrypter())]
#if canImport(PartoutOpenVPN_ObjC)
    list.append(StandardOpenVPNParser(supportsLZO: supportsLZO, decrypter: OSSLTLSBox()))
#endif
    return list
}
