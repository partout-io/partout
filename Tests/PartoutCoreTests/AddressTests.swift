// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct AddressTests {
    @Test
    func givenIPv4_whenParse_thenIsExpected() {
        #expect(Address(rawValue: "1.2.3.4") == .ip("1.2.3.4", .v4))
        #expect(Address(rawValue: "0.0.0.0") == .ip("0.0.0.0", .v4))
        #expect(Address(rawValue: "255.255.255.255") == .ip("255.255.255.255", .v4))
        #expect(Address(rawValue: " 1.2.3.4 ") == .ip("1.2.3.4", .v4))
        #expect(Address(rawValue: "1.2.3") == .ip("1.2.3", .v4))
        #expect(Address(rawValue: "-1.2.3.4") != .ip("1.2.3.4", .v4))
        #expect(Address(rawValue: "1#2.3.4") != .ip("1.2.3.4", .v4))
        #expect(Address(rawValue: "1.2.3.4.5")?.isIPAddress ?? false == false)
        #expect(Address(rawValue: "256.255.255.255")?.isIPAddress ?? false == false)
    }

    @Test
    func givenIPv4_whenParseData_thenIsExpected() {
        #expect(Address(data: Data(hex: "01020304")) == .ip("1.2.3.4", .v4))
        #expect(Address(data: Data(hex: "00000000")) == .ip("0.0.0.0", .v4))
        #expect(Address(data: Data(hex: "ffffffff")) == .ip("255.255.255.255", .v4))
    }

    @Test
    func givenIPv6_whenParse_thenIsExpected() {
        #expect(Address(rawValue: "2607:f0d0:1002:51::4") == .ip("2607:f0d0:1002:51::4", .v6))
        #expect(Address(rawValue: "::4") == .ip("::4", .v6))
        #expect(Address(rawValue: "2607:f0d0:1002:51:ffff:5435:4550:4") == .ip("2607:f0d0:1002:51:ffff:5435:4550:4", .v6))
        #expect(Address(rawValue: "  ::4  ") == .ip("::4", .v6))
        #expect(Address(rawValue: "::") == .ip("::", .v6))
        #expect(Address(rawValue: "2607:f0d0:1002:51:ffff:5435:4550:4:44")?.isIPAddress ?? false == false)
        #expect(Address(rawValue: ":1")?.isIPAddress ?? false == false)
        #expect(Address(rawValue: "g607:f0d0:1002:51::4")?.isIPAddress ?? false == false)
    }

    @Test
    func givenIPv6_whenParseData_thenIsExpected() {
        #expect(Address(data: Data(hex: "2607f0d0100200510000000000000004")) == .ip("2607:f0d0:1002:0051:0000:0000:0000:0004", .v6))
        #expect(Address(data: Data(hex: "00000000000000000000000000000004")) == .ip("0000:0000:0000:0000:0000:0000:0000:0004", .v6))
        #expect(Address(data: Data(hex: "2607f0d010020051ffff543545500004")) == .ip("2607:f0d0:1002:0051:ffff:5435:4550:0004", .v6))
    }

    @Test
    func givenHostname_whenParse_thenIsExpected() {
        #expect(Address(rawValue: "foobar") == .hostname("foobar"))
        #expect(Address(rawValue: "    ,") == .hostname(","))
    }

    @Test
    func givenCorruptIPAddress_whenParse_thenFails() {
        #expect(Address(rawValue: "") == nil)
        #expect(Address(rawValue: "    ") == nil)
        #expect(Address(rawValue: ":%:")?.isIPAddress ?? false == false)
        #expect(Address(rawValue: ":%:11")?.isIPAddress ?? false == false)
        #expect(Address(rawValue: ".")?.isIPAddress ?? false == false)
    }

    @Test
    func givenIPv4WithNetmask_whenNetwork_thenIsExpected() throws {
        let sut = try #require(Address(rawValue: "1.2.3.4"))
        #expect(sut.network(with: "0.0.0.0") == Address(rawValue: "0.0.0.0"))
        #expect(sut.network(with: "255.255.0.0") == Address(rawValue: "1.2.0.0"))
        #expect(sut.network(with: "255.255.255.0") == Address(rawValue: "1.2.3.0"))
        #expect(sut.network(with: "255.255.255.255") == Address(rawValue: "1.2.3.4"))
    }

    @Test
    func givenIPv6WithPrefix_whenNetwork_thenIsExpected() throws {
        let sut = try #require(Address(rawValue: "2f:2:33::4"))

        // 0000 0000 0010 1111 = 0-16
        // 0000 0000 0000 0010 = 16-32
        // 0000 0000 0011 0011 = 32-48
        // ...
        // 0000 0000 0000 0100 = 112-128

        #expect(sut.network(with: 0) == Address(rawValue: "::"))
        #expect(sut.network(with: 5) == Address(rawValue: "::"))
        #expect(sut.network(with: 16) == Address(rawValue: "2f::"))
        #expect(sut.network(with: 24) == Address(rawValue: "2f::"))
        #expect(sut.network(with: 30) == Address(rawValue: "2f::"))
        #expect(sut.network(with: 32) == Address(rawValue: "2f:2::"))
        #expect(sut.network(with: 43) == Address(rawValue: "2f:2:20::"))
        #expect(sut.network(with: 47) == Address(rawValue: "2f:2:32::"))
        #expect(sut.network(with: 48) == Address(rawValue: "2f:2:33::"))
        #expect(sut.network(with: 128) == Address(rawValue: "2f:2:33::4"))
    }
}
