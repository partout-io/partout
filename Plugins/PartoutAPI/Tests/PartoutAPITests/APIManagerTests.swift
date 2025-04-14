//
//  APIManagerTests.swift
//  Partout
//
//  Created by Davide De Rosa on 10/7/24.
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

import Combine
import Foundation
@testable import PartoutAPI
import PartoutCore
import XCTest

final class APIManagerTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []
}

@MainActor
extension APIManagerTests {
    func test_givenAPI_whenFetchIndex_thenReturnsProviders() async throws {
        let sut = Self.manager()

        let exp = expectation(description: "Index")
        sut
            .$providers
            .dropFirst(2) // initial, observeObjects
            .sink { _ in
                exp.fulfill()
            }
            .store(in: &subscriptions)

        try await sut.fetchIndex()
        await fulfillment(of: [exp])

        XCTAssertEqual(sut.providers.map(\.description), ["bar1", "bar2", "bar3"])
    }

    func test_givenIndex_whenFilterBySupport_thenReturnsSupportedProviders() async throws {
        let sut = Self.manager()

        let exp = expectation(description: "SupportedIndex")
        sut
            .$providers
            .dropFirst(2)
            .sink { _ in
                exp.fulfill()
            }
            .store(in: &subscriptions)

        try await sut.fetchIndex()
        await fulfillment(of: [exp])

        let supporting = sut.providers.filter {
            $0.supports(MockModule.self)
        }
        XCTAssertEqual(supporting.map(\.description), ["bar2"])
    }
}

// MARK: -

@MainActor
private extension APIManagerTests {
    static func manager() -> APIManager {
        APIManager(from: [MockAPI()], repository: MockRepository())
    }
}
