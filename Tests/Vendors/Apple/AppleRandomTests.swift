// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsApple
import Foundation
import XCTest

final class AppleRandomTests: XCTestCase {
    private let sut = AppleRandom()

    func test_givenPRNG_whenGenerateData_thenHasGivenLength() {
        XCTAssertEqual(sut.data(length: 123).count, 123)
    }

    func test_givenPRNG_whenGenerateSuite_thenHasGivenParameters() {
        let length = 52
        let elements = 680
        let suite = sut.suite(withDataLength: 52, numberOfElements: 680)

        XCTAssertEqual(suite.count, elements)
        suite.forEach {
            XCTAssertEqual($0.count, length)
        }
    }
}
