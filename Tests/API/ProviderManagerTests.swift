// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import PartoutAPI
import PartoutCore
import PartoutProviders
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

            let providerManager = APIManager(.global, from: [api], repository: repository)
            let module = try ProviderModule(emptyWithProviderId: .mock)
            try await providerManager.fetchInfrastructure(for: module)

            return repository.providerRepository(for: providerId)
        } catch {
            print("Unable to fetch API: \(error)")
            throw error
        }
    }
}
