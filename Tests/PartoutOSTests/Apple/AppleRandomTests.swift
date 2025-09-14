// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
internal import PartoutOS
import Testing

struct AppleRandomTests {
    private let sut = AppleRandom()

    @Test
    func givenPRNG_whenGenerateData_thenHasGivenLength() {
        #expect(sut.data(length: 123).count == 123)
    }

    @Test
    func givenPRNG_whenGenerateSuite_thenHasGivenParameters() {
        let length = 52
        let elements = 680
        let suite = sut.suite(withDataLength: 52, numberOfElements: 680)

        #expect(suite.count == elements)
        suite.forEach {
            #expect($0.count == length)
        }
    }
}
