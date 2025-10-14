// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct EndpointTests {
    @Test
    func givenIPv4_whenParse_thenSucceeds() throws {
        try assertEndpoint(with: "1.2.3.4", 1194, .v4)
        try assertEndpoint(with: "1.2.3.4", 1194, .v4)
        try assertEndpoint(with: "1.2.3.4", 1194, .v4)
        assertEndpointFailure(with: "1.2.3", 1194, .v4)
        assertEndpointFailure(with: "1.2.3.4.5", 1194, .v4)
    }

    @Test
    func givenIPv6_whenParse_thenSucceeds() throws {
        try assertEndpoint(with: "2607:f0d0:1002:51::4", 1194, .v6)
        try assertEndpoint(with: "2607:f0d0:1002:51::4", 1194, .v6)
        try assertEndpoint(with: "2607:f0d0:1002:51::4", 1194, .v6)
        try assertEndpoint(with: "4::", 1194, .v6)
        assertEndpointFailure(with: "::4::", 1194, .v6)
    }
}

private extension EndpointTests {
    func assertEndpoint(with ipAddress: String, _ port: UInt16, _ family: Address.Family) throws {
        let sut = try #require(Endpoint(rawValue: "\(ipAddress):\(port)"))
        #expect(sut.address.rawValue == ipAddress)
        #expect(sut.address.family == family)
        #expect(sut.port == port)
    }

    func assertEndpointFailure(with ipAddress: String, _ port: UInt16, _ family: Address.Family) {
        #expect(Endpoint(rawValue: "\(ipAddress):\(port)")?.address.family != family)
    }
}
