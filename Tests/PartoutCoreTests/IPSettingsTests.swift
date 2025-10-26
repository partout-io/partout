// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct IPSettingsTests {
    @Test
    func givenIPv4_whenIncludeIPv4Routes_thenIncludesRoutes() throws {
        let subnet = try #require(Subnet(rawValue: "10.0.0.0/16"))
        let defaultGw = try #require(Address(rawValue: "6.6.6.6"))
        var sut = IPSettings(subnet: subnet)
        sut = sut.including(routes: [
            .init(.init(rawValue: "1.0.0.0/12"), nil),
            .init(.init(rawValue: "5.5.0.0/24"), nil),
            .init(defaultWithGateway: defaultGw)
        ])
        #expect(sut.includedRoutes.contains {
            $0.destination == .init(rawValue: "1.0.0.0/12")
        })
        #expect(sut.includedRoutes.contains {
            $0.destination == .init(rawValue: "5.5.0.0/24")
        })
        #expect(!sut.includedRoutes.contains {
            $0.destination == .init(rawValue: "100.100.0.0/32")
        })
        #expect(sut.includesDefaultRoute)
    }

    @Test
    func givenIPv4_whenExcludeIPv4Routes_thenExcludesRoutes() throws {
        let subnet = try #require(Subnet(rawValue: "10.0.0.0/16"))
        let defaultGw = try #require(Address(rawValue: "6.6.6.6"))
        var sut = IPSettings(subnet: subnet)
        sut = sut.excluding(routes: [
            .init(.init(rawValue: "1.0.0.0/12"), nil),
            .init(.init(rawValue: "5.5.0.0/24"), nil),
            .init(defaultWithGateway: defaultGw)
        ])
        #expect(sut.excludedRoutes.contains {
            $0.destination == .init(rawValue: "1.0.0.0/12")
        })
        #expect(sut.excludedRoutes.contains {
            $0.destination == .init(rawValue: "5.5.0.0/24")
        })
        #expect(!sut.excludedRoutes.contains {
            $0.destination == .init(rawValue: "100.100.0.0/32")
        })
    }

    @Test
    func givenIPv6_whenParse_thenSucceeds() {
    }
}
