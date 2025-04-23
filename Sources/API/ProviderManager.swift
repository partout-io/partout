//
//  ProviderManager.swift
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
import PartoutCore
import PartoutProviders

@MainActor
public final class ProviderManager: ObservableObject {
    private let sorting: [ProviderSortField]

    public private(set) var moduleType: ModuleType

    private var repository: ProviderRepository

    public private(set) var options: ProviderFilterOptions

    private var filterTask: Task<[ProviderServer], Error>?

    public init(sorting: [ProviderSortField] = []) {
        self.sorting = sorting
        moduleType = ModuleType("")
        repository = DummyRepository()
        options = ProviderFilterOptions()
    }
}

extension ProviderManager {
    public func setRepository(_ repository: ProviderRepository, for moduleType: ModuleType) async throws {
        self.moduleType = moduleType
        self.repository = repository
        options = try await repository.availableOptions(for: moduleType)
        objectWillChange.send()
    }

    public var providerId: ProviderID {
        guard !(repository is DummyRepository) else {
            fatalError("Call setRepository() first")
        }
        return repository.providerId
    }

    public var presets: [ProviderPreset] {
        Array(options.presets.filter {
            $0.moduleType == moduleType
        })
    }

    public func filteredServers(with filters: ProviderFilters? = nil) async throws -> [ProviderServer] {
        if let filterTask {
            _ = try await filterTask.value
        }
        filterTask = Task {
            try await rawApplyFilters(filters)
        }
        let servers = try await filterTask!.value
        filterTask = nil
        return servers
    }
}

private extension ProviderManager {
    func rawApplyFilters(_ filters: ProviderFilters?) async throws -> [ProviderServer] {
        var parameters = ProviderServerParameters(sorting: sorting)
        if let filters {
            parameters.filters = filters
            parameters.filters.moduleType = moduleType
        }
        return try await repository.filteredServers(with: parameters)
    }
}

// MARK: - Dummy

private final class DummyRepository: ProviderRepository {
    let providerId = ProviderID(rawValue: "")

    func availableOptions(for moduleType: ModuleType) async throws -> ProviderFilterOptions {
        ProviderFilterOptions()
    }

    func filteredServers(with parameters: ProviderServerParameters?) -> [ProviderServer] {
        []
    }
}
