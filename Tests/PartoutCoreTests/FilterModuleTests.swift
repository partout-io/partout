// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct FilterModuleTests {
    @Test
    func givenModule_whenRebuild_thenIsRestored() throws {
        let sut = FilterModule.Builder(
            disabledMask: [
                .ipv4,
                .ipv6,
                .dns,
                .proxy,
                .mtu
            ]
        )
        let module = sut.build()
        #expect(sut == module.builder())
    }
}
