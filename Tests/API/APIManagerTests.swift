// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Combine)

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
        APIManager(.global, from: [MockAPI()], repository: MockRepository())
    }
}

#endif
