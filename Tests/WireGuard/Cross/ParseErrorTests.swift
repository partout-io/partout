// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutWireGuard
import PartoutCore
import XCTest

final class ParseErrorTests: XCTestCase {
    func test_givenParseError_whenMap_thenReturnsAsReason() throws {
        let sut = WireGuardParseError.noInterface
        let mapped = sut.asPartoutError
        XCTAssertTrue(mapped.reason is WireGuardParseError)
        let reason = try XCTUnwrap(mapped.reason as? WireGuardParseError)
        switch reason {
        case .noInterface:
            break
        default:
            XCTFail("Mapped to different error: \(reason)")
        }
    }
}
