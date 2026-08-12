// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct HTTPProxyModuleTests {
    @Test
    func givenHTTP_whenRebuild_thenIsRestored() throws {
        let sut = HTTPProxyModule.Builder(
            address: "1.2.3.4",
            port: 8080
        )
        #expect(try sut.build().builder() == sut)
    }

    @Test
    func givenHTTPS_whenRebuild_thenIsRestored() throws {
        let sut = HTTPProxyModule.Builder(
            secureAddress: "1.2.3.4",
            securePort: 8080
        )
        #expect(try sut.build().builder() == sut)
    }

    @Test
    func givenHTTPAndHTTPS_whenRebuild_thenIsRestored() throws {
        let sut = HTTPProxyModule.Builder(
            address: "1.2.3.4",
            port: 8080,
            secureAddress: "1.2.3.4",
            securePort: 8080
        )
        #expect(try sut.build().builder() == sut)
    }

    @Test
    func givenHTTPWithMalformedEndpoint_whenBuild_thenFails() {
        let sut = HTTPProxyModule.Builder(
            address: "1.2.3.4.5",
            port: 12345
        )
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenHTTPWithNonDomainBypassDomains_whenBuild_thenFails() {
        let sut = HTTPProxyModule.Builder(
            address: "1.2.3.4",
            port: 12345,
            bypassDomains: ["1.1.1.1"]
        )
        #expect(throws: Error.self) {
            try sut.build()
        }
    }

    @Test
    func givenPACURL_whenRebuild_thenIsRestored() throws {
        let sut = HTTPProxyModule.Builder(
            pacURLString: "https://some.pac"
        )
        #expect(try sut.build().builder() == sut)
    }

    @Test
    func givenPACURLWithNonDomainBypassDomains_whenBuild_thenFails() {
        let sut = HTTPProxyModule.Builder(
            pacURLString: "https://some.pac",
            bypassDomains: ["1.1.1.1"]
        )
        #expect(throws: Error.self) {
            try sut.build()
        }
    }
}
