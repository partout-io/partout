// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct OnDemandModuleTests {
    @Test
    func givenBuilder_whenRebuild_thenIsRestored() {
        var sut: OnDemandModule.Builder

        sut = OnDemandModule.Builder()
        sut.policy = .any
        sut.withSSIDs = [
            "one": true,
            "two": false
        ]
        sut.withMobileNetwork = true
        sut.withEthernetNetwork = true
        #expect(sut.build().builder() == sut)

        sut.policy = .including
        #expect(sut.build().builder() == sut)

        sut.policy = .excluding
        #expect(sut.build().builder() == sut)

        sut.withSSIDs = [:]
        sut.withMobileNetwork = false
        sut.withEthernetNetwork = false
        #expect(sut.withOtherNetworks == [])
        #expect(sut.build().builder() == sut)
    }

    @Test
    func givenBuilder_whenSetOtherNetworks_thenReflects() {
        var sut = OnDemandModule.Builder()

        sut.withMobileNetwork = true
        sut.withEthernetNetwork = true
        #expect(sut.withOtherNetworks == [.ethernet, .mobile])

        sut.withOtherNetworks = []
        #expect(!sut.withMobileNetwork)
        #expect(!sut.withEthernetNetwork)

        sut.withOtherNetworks = [.mobile]
        #expect(sut.withMobileNetwork)
        #expect(!sut.withEthernetNetwork)

        sut.withOtherNetworks = [.ethernet]
        #expect(!sut.withMobileNetwork)
        #expect(sut.withEthernetNetwork)
    }
}
