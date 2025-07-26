// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import XCTest

final class PartoutCoreTests: XCTestCase {
    func test_givenCore_whenCreateProfileBuilder_thenWorks() {
        var profile = Profile.Builder(activatingModules: true)
        profile.name = "foobar"
        XCTAssertEqual(profile.name, "foobar")
    }
}
