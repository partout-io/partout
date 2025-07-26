// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import PartoutOpenVPNLegacy
import PartoutCore
import XCTest

final class ZeroingDataExtensionsTests: XCTestCase {
    func test_givenPRNG_whenGenerateSafeData_thenHasGivenLength() {
        let sut = SimplePRNG()
        XCTAssertEqual(sut.safeData(length: 500).length, 500)
    }

    func test_givenZeroingData_whenAsSensitive_thenOmitsSensitiveData() throws {
        let sut = Z(Data(hex: "12345678abcdef"))
        XCTAssertEqual(sut.debugDescription(withSensitiveData: true), "[7 bytes, 12345678abcdef]")
        XCTAssertEqual(sut.debugDescription(withSensitiveData: false), "[7 bytes]")
    }
}
