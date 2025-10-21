// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct IPModuleTests {
    @Test
    func givenIPv4_whenRebuild_thenIsRestored() {
        let sut = IPModule.Builder(
            ipv4: IPSettings(subnet: Subnet(rawValue: "1.2.3.4/16")!)
        )
        #expect(sut.build().builder() == sut)
    }

    @Test
    func givenIPv6_whenRebuild_thenIsRestored() {
        let sut = IPModule.Builder(
            ipv6: IPSettings(subnet: Subnet(rawValue: "1:2:3::4/120")!)
        )
        #expect(sut.build().builder() == sut)
    }
}
