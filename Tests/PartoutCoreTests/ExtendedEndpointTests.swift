// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ExtendedEndpointTests {
    @Test
    func givenIPv4_whenParse_thenSucceeds() throws {
        try assertEndpoint(with: "1.2.3.4", "TCP", 1194, .v4)
        try assertEndpoint(with: "1.2.3.4", "UDP6", 1194, .v4)
        try assertEndpoint(with: "1.2.3.4", "TCP6", 1194, .v4)
        assertEndpointFailure(with: "1.2.3.4.5", "TCP", 1194, .v4)
        assertEndpointFailure(with: "1.2.3.4", "TCP5", 1194, .v4)
    }

    @Test
    func givenIPv6_whenParse_thenSucceeds() throws {
        try assertEndpoint(with: "2607:f0d0:1002:51::4", "TCP", 1194, .v6)
        try assertEndpoint(with: "2607:f0d0:1002:51::4", "TCP4", 1194, .v6)
        try assertEndpoint(with: "2607:f0d0:1002:51::4", "UDP6", 1194, .v6)
        assertEndpointFailure(with: "::4::", "UDP6", 1194, .v6)
        assertEndpointFailure(with: "::4", "UDP7", 1194, .v6)
    }
}

private extension ExtendedEndpointTests {
    func assertEndpoint(with ipAddress: String, _ socketType: String, _ port: UInt16, _ family: Address.Family) throws {
        let sut = try #require(ExtendedEndpoint(rawValue: "\(ipAddress):\(socketType):\(port)"))
        #expect(sut.address.rawValue == ipAddress)
        #expect(sut.proto.socketType.rawValue == socketType)
        #expect(sut.proto.port == port)

        switch family {
        case .v4:
            #expect(sut.isIPv4)
            #expect(!sut.isIPv6)

        case .v6:
            #expect(!sut.isIPv4)
            #expect(sut.isIPv6)
        }
    }

    func assertEndpointFailure(with ipAddress: String, _ socketType: String, _ port: UInt16, _ family: Address.Family) {
        #expect(ExtendedEndpoint(rawValue: "\(ipAddress):\(socketType):\(port)")?.address.family != family)
    }
}
