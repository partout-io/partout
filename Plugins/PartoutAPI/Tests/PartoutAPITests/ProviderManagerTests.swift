//
//  ProviderManagerTests.swift
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
@testable import PartoutCore
import XCTest

final class ProviderManagerTests: XCTestCase {
}

@MainActor
extension ProviderManagerTests {
    func test_givenManager_whenFetchSupportedPresets_thenIsNotEmpty() async throws {
        let repository = try await Self.repository(for: .mock)
        let sut = ProviderManager()
        try await sut.setRepository(repository, for: MockModule.moduleHandler.id)

        print(sut.presets)
        XCTAssertEqual(sut.presets.count, 1)
    }

    func test_givenManager_whenFetchUnsupportedPresets_thenIsEmpty() async throws {
        let repository = try await Self.repository(for: .mock)
        let sut = ProviderManager()
        try await sut.setRepository(repository, for: MockUnsupportedModule.moduleHandler.id)

        print(sut.presets)
        XCTAssertTrue(sut.presets.isEmpty)
    }

    func test_givenManager_whenSetProvider_thenReturnsServers() async throws {
        let repository = try await Self.repository(for: .mock)
        let sut = ProviderManager()
        try await sut.setRepository(repository, for: MockModule.moduleHandler.id)

        XCTAssertEqual(sut.options.countryCodes.count, 1)
        let servers = try await sut.filteredServers()
        XCTAssertEqual(servers.count, 1)

        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server.metadata.countryCode, "US")

        let ipAddresses = server.ipAddresses?.compactMap {
            Address(data: $0)
        } ?? []
        XCTAssertEqual(ipAddresses.map(\.rawValue), ["1.2.3.4"])
    }

    func test_givenManager_whenSetFilters_thenReturnsFilteredServers() async throws {
        let repository = try await Self.repository(for: .mock)
        let sut = ProviderManager()
        try await sut.setRepository(repository, for: MockModule.moduleHandler.id)

        var filters = ProviderFilters()
        filters.categoryName = "foobar"
        let servers = try await sut.filteredServers(with: filters)
        XCTAssertTrue(servers.isEmpty)
    }

    func test_givenManager_whenSetFiltersThenReset_thenReturnsAllServers() async throws {
        let repository = try await Self.repository(for: .mock)
        let sut = ProviderManager()
        try await sut.setRepository(repository, for: MockModule.moduleHandler.id)

        var filters = ProviderFilters()
        filters.categoryName = "foobar"
        var servers = try await sut.filteredServers(with: filters)
        servers = try await sut.filteredServers()
        XCTAssertEqual(servers.count, 1)
    }
}

// MARK: -

@MainActor
private extension ProviderManagerTests {
    static func yield() async {
        try? await Task.sleep(milliseconds: 100)
    }

    static func repository(for providerId: ProviderID) async throws -> ProviderRepository {
        do {
            let api = MockAPI()
            let repository = MockRepository()

            let providerManager = APIManager(from: [api], repository: repository)
            try await providerManager.fetchInfrastructure(for: .mock)

            return repository.providerRepository(for: providerId)
        } catch {
            print("Unable to fetch API: \(error)")
            throw error
        }
    }
}
