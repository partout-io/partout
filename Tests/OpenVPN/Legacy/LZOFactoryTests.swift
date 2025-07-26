// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import XCTest

final class LZOFactoryTests: XCTestCase {
    func test_givenLibrary_whenCheckLZOSupport_thenSucceeds() {
        XCTAssertTrue(LZOFactory.canCreate())
        XCTAssertNotNil(LZOFactory.create())
    }
}
