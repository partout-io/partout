// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutVendorsPortable
import XCTest

final class CZeroingDataExtensionsTests: XCTestCase {
    func test_givenZeroingData_whenAsSensitive_thenOmitsSensitiveData() throws {
        let sut = CZX("12345678abcdef")
        XCTAssertEqual(sut.debugDescription(withSensitiveData: true), "[7 bytes, 12345678abcdef]")
        XCTAssertEqual(sut.debugDescription(withSensitiveData: false), "[7 bytes]")
    }
}
