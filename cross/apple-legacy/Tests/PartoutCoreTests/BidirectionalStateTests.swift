// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct BidirectionalStateTests {
    @Test
    func givenState_whenReset_thenRestarts() {
        let value = "initial"
        var sut = BidirectionalState(withResetValue: value)
        sut.inbound = "in"
        sut.outbound = "out"
        sut.reset()
        #expect(sut.inbound == value)
        #expect(sut.outbound == value)
    }
}
