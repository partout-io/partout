// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutWireGuard
@testable import PartoutWireGuardCross
import PartoutCore
import Testing

struct StandardWireGuardParserTests {
    private let parser = StandardWireGuardParser()

    private let keyGenerator = StandardWireGuardKeyGenerator()

    // MARK: - Interface

    @Test
    func givenParser_whenGoodBuilder_thenDoesNotThrow() throws {
        var sut = newBuilder()
        sut.interface.addresses = ["1.2.3.4"]

        var dns = DNSModule.Builder()
        dns.servers = ["1.2.3.4"]
        dns.searchDomains = ["domain.local"]
        sut.interface.dns = dns

        let builder = WireGuardModule.Builder(configurationBuilder: sut)
        try parser.validate(builder)
    }

    @Test
    func givenParser_whenBadPrivateKey_thenThrows() {
        let sut = WireGuard.Configuration.Builder(privateKey: "")
        do {
            try assertValidationFailure(sut)
        } catch {
            assertParseError(error) {
                guard case .interfaceHasInvalidPrivateKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test
    func givenParser_whenBadAddresses_thenThrows() {
        var sut = newBuilder()
        sut.interface.addresses = ["dsfds"]
        do {
            try assertValidationFailure(sut)
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

    @Test
    func givenParser_whenBadPeerPublicKey_thenThrows() {
        var sut = newBuilder(withInterface: true)

        let peer = WireGuard.RemoteInterface.Builder(publicKey: "")
        sut.peers = [peer]

        do {
            try assertValidationFailure(sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidPublicKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test
    func givenParser_whenBadPeerPresharedKey_thenThrows() {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.preSharedKey = "fdsfokn.,x"
        sut.peers = [peer]

        do {
            try assertValidationFailure(sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidPreSharedKey = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test
    func givenParser_whenBadPeerEndpoint_thenThrows() {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.endpoint = "fdsfokn.,x"
        sut.peers = [peer]

        do {
            try assertValidationFailure(sut)
        } catch {
            assertParseError(error) {
                guard case .peerHasInvalidEndpoint = $0 else {
                    #expect(Bool(false), "\($0.localizedDescription)")
                    return
                }
            }
        }
    }

    @Test
    func givenParser_whenBadPeerAllowedIPs_thenThrows() {
        var sut = newBuilder(withInterface: true, withPeer: true)
        var peer = sut.peers[0]
        peer.allowedIPs = ["fdsfokn.,x"]
        sut.peers = [peer]

        do {
            try assertValidationFailure(sut)
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

private extension StandardWireGuardParserTests {
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

    func assertValidationFailure(_ wgBuilder: WireGuard.Configuration.Builder) throws {
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
