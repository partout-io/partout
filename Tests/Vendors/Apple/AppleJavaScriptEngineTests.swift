//
//  AppleJavaScriptEngineTests.swift
//  Partout
//
//  Created by Davide De Rosa on 3/26/25.
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

import _PartoutVendorsApple
import Foundation
import XCTest

final class AppleJavaScriptEngineTests: XCTestCase {
    func test_givenEngine_whenInject_thenReturns() async throws {
        let sut = AppleJavaScriptEngine(.global)
        sut.inject("triple", object: {
            3 * $0
        } as @convention(block) (Int) -> Int)
        let result = try await sut.execute("""
triple(40);
""", after: nil, returning: Int.self)
        XCTAssertEqual(result, 120)
    }
}
