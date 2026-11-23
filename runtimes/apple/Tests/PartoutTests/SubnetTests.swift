// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct SubnetTests {
    @Test
    func givenIPv4_whenParse_thenSucceeds() throws {
        try assertSubnet(with: "1.2.3.4", 0, .v4)
        try assertSubnet(with: "1.2.3.4", 16, .v4)
        try assertSubnet(with: "1.2.3.4", 32, .v4)
        assertSubnetFailure(with: "1.2.3.4.5", 16, .v4)
    }

    @Test(arguments: [
        ("1.2.3", "1.2.0.3"),
        ("192.168", "192.0.0.168"),
        ("2130706433", "127.0.0.1"),
        ("0x7f000001", "127.0.0.1"),
        ("::ffff:192.168.1.1", "192.168.1.1")
    ])
    func givenNonCanonicalIPv4_whenEncode_thenUsesDottedDecimal(raw: String, canonical: String) throws {
        let address = try #require(Address(rawValue: raw))
        #expect(address == .ip(canonical, .v4))
        #expect(try JSONEncoder.shared().encodeJSON(address) == "\"\(canonical)\"")

        let subnet = try Subnet(raw, 24)
        #expect(subnet.rawValue == "\(canonical)/24")
        let json = try JSONEncoder.shared().encode(subnet)
        #expect(try JSONDecoder.shared().decode(String.self, from: json) == "\(canonical)/24")
        #expect(try JSONDecoder.shared().decode(Subnet.self, from: json) == subnet)
    }

    @Test(arguments: ["fe80::1%en0", "fe80::1%1"])
    func givenScopedIPv6_whenParseSubnet_thenFails(raw: String) {
        #expect(Subnet(.ip(raw, .v6), 64) == nil)
        #expect(Subnet(rawValue: raw) == nil)
        #expect(Subnet(rawValue: "\(raw)/64") == nil)
        #expect(throws: PartoutError.self) {
            try Subnet(raw, 64)
        }
    }

    @Test
    func givenIPv6_whenParse_thenSucceeds() throws {
        try assertSubnet(with: "2607:f0d0:1002:51::4", 0, .v6)
        try assertSubnet(with: "2607:f0d0:1002:51::4", 48, .v6)
        try assertSubnet(with: "2607:f0d0:1002:51::4", 128, .v6)
        try assertSubnet(with: "4::", 72, .v6)
        assertSubnetFailure(with: "::4::", 72, .v6)
    }

    @Test
    func givenIPv4_whenNetmask_thenSucceeds() throws {
        #expect(try Subnet("1.2.3.4", 0).ipv4Mask == "0.0.0.0")
        #expect(try Subnet("1.2.3.4", 1).ipv4Mask == "128.0.0.0")
        #expect(try Subnet("1.2.3.4", 16).ipv4Mask == "255.255.0.0")
        #expect(try Subnet("1.2.3.4", 24).ipv4Mask == "255.255.255.0")
        #expect(try Subnet("1.2.3.4", 31).ipv4Mask == "255.255.255.254")
        #expect(try Subnet("1.2.3.4", 32).ipv4Mask == "255.255.255.255")
    }

    @Test
    func givenIPv4WithNetmask_whenParse_thenHasRightPrefix() throws {
        #expect(try Subnet("1.2.3.4", "0.0.0.0").prefixLength == 0)
        #expect(try Subnet("1.2.3.4", "128.0.0.0").prefixLength == 1)
        #expect(try Subnet("1.2.3.4", "255.255.0.0").prefixLength == 16)
        #expect(try Subnet("1.2.3.4", "255.255.255.0").prefixLength == 24)
        #expect(try Subnet("1.2.3.4", "255.255.255.254").prefixLength == 31)
        #expect(try Subnet("1.2.3.4", "255.255.255.255").prefixLength == 32)
    }
}

private extension SubnetTests {
    func assertSubnet(with ipAddress: String, _ prefixLength: Int, _ family: Address.Family) throws {
        let sut = try #require(Subnet(rawValue: "\(ipAddress)/\(prefixLength)"))
        #expect(sut.address.rawValue == ipAddress)
        #expect(sut.prefixLength == prefixLength)
    }

    func assertSubnetFailure(with ipAddress: String, _ prefixLength: Int, _ family: Address.Family) {
        #expect(Subnet(rawValue: "\(ipAddress)/\(prefixLength)")?.address.family != family)
    }
}
