// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
internal import _PartoutCore_C
#if canImport(Network)
import Network
#endif
import Testing

struct DataNetworkTests {
    @Test
    func givenData_whenParse_thenSucceeds() {
        let sut = Data(hex: "00000000")
        #expect(sut.asIPAddress == "0.0.0.0")
    }

#if canImport(Network)
    @Test
    func givenIPv4_whenParse_thenSucceeds() throws {
        let sut = "1.2.3.4"
        let addr = Network.IPv4Address(sut)
        let ipv4 = try #require(addr)
        #expect(ipv4.rawValue.asIPAddress == sut)
    }

    @Test
    func givenIPv6_whenParse_thenSucceeds() throws {
        let sut = "11:2::3:4"
        let addr = Network.IPv6Address(sut)
        let ipv6 = try #require(addr)
        #expect(ipv6.rawValue.asIPAddress == sut)
    }
#endif
}
