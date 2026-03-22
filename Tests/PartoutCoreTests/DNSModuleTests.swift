// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Foundation
import Testing

struct DNSModuleTests {
    @Test
    func givenPlain_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .cleartext,
            servers: ["1.2.3.4"]
        )
        let module = try sut.build()
        #expect(sut == module.builder())
    }

    @Test
    func givenHTTPS_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .https,
            servers: ["1.2.3.4"],
            dohURL: "https://1.2.3.4/"
        )
        let module = try sut.build()
        #expect(sut == module.builder())
    }

    @Test
    func givenTLS_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.2.3.4"],
            dotHostname: "example.com"
        )
        let module = try sut.build()
        #expect(sut == module.builder())
    }

    @Test
    func givenHTTPSWithoutURL_whenBuild_thenFails() {
        let sut = DNSModule.Builder(
            protocolType: .https,
            servers: ["1.2.3.4"]
        )
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenTLSWithoutDomain_whenBuild_thenFails() {
        let sut = DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.2.3.4"]
        )
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenCleartext_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.cleartext)
    }

    @Test
    func givenTaggedHTTPS_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.https(url: try #require(URL(string: "https://1.2.3.4/"))))
    }

    @Test
    func givenTaggedTLS_whenEncodeDecode_thenIsReversible() throws {
        try assertRoundTrip(.tls(hostname: "example.com"))
    }

    @Test
    func givenLegacyHTTPSPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"https":{"url":"https://1.2.3.4/"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DNSModule.ProtocolType.self, from: data)
        #expect(decoded == .https(url: try #require(URL(string: "https://1.2.3.4/"))))
    }

    @Test
    func givenLegacyCleartextPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"cleartext":{}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DNSModule.ProtocolType.self, from: data)
        #expect(decoded == .cleartext)
    }

    @Test
    func givenLegacyTLSPayload_whenDecode_thenRestoresValue() throws {
        let data = #"{"tls":{"hostname":"example.com"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DNSModule.ProtocolType.self, from: data)
        #expect(decoded == .tls(hostname: "example.com"))
    }

    @Test
    func givenMalformedTaggedHTTPSPayload_whenDecode_thenFailsWithoutLegacyFallback() {
        let data = #"{"type":"https","hostname":"example.com"}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(DNSModule.ProtocolType.self, from: data)
        }
    }

    @Test
    func givenMalformedLegacyHTTPSPayload_whenDecode_thenFailsWithoutTryingOtherLegacyCases() {
        let data = #"{"https":{"hostname":"example.com"}}"#.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(DNSModule.ProtocolType.self, from: data)
        }
    }
}

private extension DNSModuleTests {
    func assertRoundTrip(_ value: DNSModule.ProtocolType) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(DNSModule.ProtocolType.self, from: encoded)
        #expect(decoded == value)
    }
}
