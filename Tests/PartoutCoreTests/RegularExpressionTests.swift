// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

struct RegularExpressionTests {
    @Test
    func givenRegex_whenGetGroups_thenAreParsedCorrectly() {
        let sut = RegularExpression("([0-9]+)([A-z]+)([0-9]+)")
        #expect(sut.groups(in: "12some80") == ["12", "some", "80"])
    }
}
