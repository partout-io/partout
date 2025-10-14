// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct DNSModuleTests {
    @Test
    func givenPlain_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .cleartext,
            servers: ["1.2.3.4"]
        )
        let module = try sut.tryBuild()
        #expect(sut == module.builder())
    }

    @Test
    func givenHTTPS_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .https,
            servers: ["1.2.3.4"],
            dohURL: "https://1.2.3.4/"
        )
        let module = try sut.tryBuild()
        #expect(sut == module.builder())
    }

    @Test
    func givenTLS_whenRebuild_thenIsRestored() throws {
        let sut = DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.2.3.4"],
            dotHostname: "example.com"
        )
        let module = try sut.tryBuild()
        #expect(sut == module.builder())
    }

    @Test
    func givenHTTPSWithoutURL_whenBuild_thenFails() {
        let sut = DNSModule.Builder(
            protocolType: .https,
            servers: ["1.2.3.4"]
        )
        #expect(throws: Error.self) {
            try sut.tryBuild()
        }
    }

    @Test
    func givenTLSWithoutDomain_whenBuild_thenFails() {
        let sut = DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.2.3.4"]
        )
        #expect(throws: Error.self) {
            try sut.tryBuild()
        }
    }
}
