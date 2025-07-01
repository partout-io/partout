//
//  BackendTests.swift
//  Partout
//
//  Created by Davide De Rosa on 6/30/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import _PartoutWireGuardGo
import wg_go
import XCTest

final class BackendTests: XCTestCase {
    func test_givenBackend_whenGetVersion_thenIsExpected() throws {
        let version = "f333402"
        let versionGo = String(cString: try XCTUnwrap(wgVersion()))
        let versionSwift = try XCTUnwrap(WireGuardBackendGo().version())
        XCTAssertEqual(versionGo, versionSwift)
        XCTAssertEqual(versionGo, version)
        print("WireGuard version: \(version)")
    }
}
