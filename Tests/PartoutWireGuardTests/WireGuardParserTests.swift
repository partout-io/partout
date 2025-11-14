// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutWireGuard
import Testing

@Suite
struct WireGuardParserTests {
    private static let crossParser = StandardWireGuardParser()
    private static var allParsers: [ModuleBuilderValidator] {
        [crossParser]
    }

    private let keyGenerator = StandardWireGuardKeyGenerator()

    // MARK: - Single entities

    @Test
    func givenEndpointString_whenMapped_thenReverts() throws {
        let sut = [
            "1.2.3.4:10000",
            "[1:2:3::4]:10000"
        ]
        let expected: [(String, UInt16)] = [
            ("1.2.3.4", 10000),
            ("1:2:3::4", 10000)
        ]
        for (i, raw) in sut.enumerated() {
            let wg = try #require(Endpoint(withWgRepresentation: raw))
            let pair = expected[i]
            #expect(wg.address.rawValue == pair.0)
            #expect(wg.port == pair.1)
        }
    }

    @Test
    func givenConfigurationWithAllowedIPs_whenMapped_thenReverts() throws {
        let quickConfig = """
[Interface]
PrivateKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
Address = 10.8.0.6/24
DNS = 1.1.1.1

[Peer]
PublicKey = muwialz9E36nXp9qgbGIxwMrH+5Ovr8d7cutH8JHdvE=
PresharedKey = 4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=
AllowedIPs = 8.8.4.0/24, 8.8.8.0/24, 8.34.208.0/20, 8.35.192.0/20, 23.236.48.0/20, 23.251.128.0/19, 212.188.34.209/32, 172.217.169.138/32, 142.250.187.106/32, 142.250.186.33/32, 172.217.17.23/32
PersistentKeepalive = 0
Endpoint = 1.2.3.4:12345
"""
        let sut = try WireGuard.Configuration(fromWgQuickConfig: quickConfig)
        #expect(sut.peers.first?.allowedIPs.map(\.rawValue) == [
            "8.8.4.0/24", "8.8.8.0/24", "8.34.208.0/20", "8.35.192.0/20",
            "23.236.48.0/20", "23.251.128.0/19", "212.188.34.209/32", "172.217.169.138/32",
            "142.250.187.106/32", "142.250.186.33/32", "172.217.17.23/32"
        ])
    }

    // MARK: - Interface

    @Test(arguments: allParsers)
    func givenParser_whenGoodBuilder_thenDoesNotThrow(parser: ModuleBuilderValidator) throws {
        var sut = newBuilder()
        sut.interface.addresses = ["1.2.3.4"]

        var dns = DNSModule.Builder()
        dns.servers = ["1.2.3.4"]
        dns.searchDomains = ["domain.local"]
        sut.interface.dns = dns

        let builder = WireGuardModule.Builder(configurationBuilder: sut)
        try parser.validate(builder)
    }

    @Test(arguments: allParsers)
    func givenParser_whenBadPrivateKey_thenThrows(parser: ModuleBuilderValidator) {
        let sut = WireGuard.Configuration.Builder(privateKey: "")
        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .interfaceHasInvalidPrivateKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test(arguments: allParsers)
    func givenParser_whenBadAddresses_thenThrows(parser: ModuleBuilderValidator) {
        var sut = newBuilder()
        sut.interface.addresses = ["dsfds"]
        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .interfaceHasInvalidAddress = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    // parser is too tolerant, never fails
//    @Test
//    func givenParser_whenBadDNS_thenThrows() {
//        var sut = newBuilder()
//        sut.interface.addresses = ["1.2.3.4"]
//
//        var dns = DNSModule.Builder()
//        dns.servers = ["1.a.2.$%3"]
//        dns.searchDomains = ["-invalid.example.com"]
//        sut.interface.dns = dns
//
//        do {
//            try assertValidationFailure(sut)
//        } catch {
//            assertParseError(error) {
//                guard case .interfaceHasInvalidDNS = $0 else {
//                    XCTFail($0.localizedDescription)
//                    return
//                }
//            }
//        }
//    }

    // MARK: - Peers

    @Test(arguments: allParsers)
    func givenParser_whenBadPeerPublicKey_thenThrows(parser: ModuleBuilderValidator) {
        var sut = newBuilder(withInterface: true)

        let peer = WireGuard.RemoteInterface.Builder(publicKey: "")
        sut.peers = [peer]

        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidPublicKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test(arguments: allParsers)
    func givenParser_whenBadPeerPresharedKey_thenThrows(parser: ModuleBuilderValidator) {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.preSharedKey = "fdsfokn.,x"
        sut.peers = [peer]

        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidPreSharedKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test(arguments: allParsers)
    func givenParser_whenBadPeerEndpoint_thenThrows(parser: ModuleBuilderValidator) {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.endpoint = "fdsfokn.,x"
        sut.peers = [peer]

        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidEndpoint = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test(arguments: allParsers)
    func givenParser_whenBadPeerAllowedIPs_thenThrows(parser: ModuleBuilderValidator) {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.allowedIPs = ["fdsfokn.,x"]
        sut.peers = [peer]

        do {
            try assertValidationFailure(parser, sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidAllowedIP = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }
}

private extension WireGuardParserTests {
    func newBuilder(withInterface: Bool = false, withPeer: Bool = false) -> WireGuard.Configuration.Builder {
        var builder = WireGuard.Configuration.Builder(keyGenerator: keyGenerator)
        if withInterface {
            builder.interface.addresses = ["1.2.3.4"]
            var dns = DNSModule.Builder()
            dns.servers = ["1.2.3.4"]
            dns.searchDomains = ["domain.local"]
            builder.interface.dns = dns
        }
        if withPeer {
            let peerPrivateKey = keyGenerator.newPrivateKey()
            do {
                let publicKey = try keyGenerator.publicKey(for: peerPrivateKey)
                builder.peers = [WireGuard.RemoteInterface.Builder(publicKey: publicKey)]
            } catch {
                #expect(Bool(false), "\(error.localizedDescription)")
                return builder
            }
        }
        return builder
    }

    func assertValidationFailure(_ parser: ModuleBuilderValidator, _ wgBuilder: WireGuard.Configuration.Builder) throws {
        let builder = WireGuardModule.Builder(configurationBuilder: wgBuilder)
        #expect(throws: Error.self) {
            try parser.validate(builder)
        }
    }

    func assertParseError(_ error: Error, _ block: (WireGuardParseError) -> Void) {
        print("Thrown: \(error.localizedDescription)")
        guard let ppError = error as? PartoutError else {
            #expect(Bool(false), "Not a PartoutError")
            return
        }
        guard let parseError = ppError.reason as? WireGuardParseError else {
            #expect(Bool(false), "Not a TunnelConfiguration.ParseError")
            return
        }
        block(parseError)
    }
}
