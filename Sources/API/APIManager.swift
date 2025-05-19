//
//  APIManager.swift
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

import Foundation
import PartoutCore
import PartoutProviders

#if canImport(Combine)
import Combine

extension APIManager: ObservableObject {
}
#endif

@MainActor
public final class APIManager {
    private enum PendingService: Hashable {
        case index

        case provider(ProviderID)
    }

    private let ctx: PartoutLoggerContext

    private let apis: [APIMapper]

    private let repository: APIRepository

#if canImport(Combine)
    @Published
#endif
    public private(set) var providers: [Provider]

#if canImport(Combine)
    @Published
#endif
    public private(set) var cache: [ProviderID: ProviderCache]

#if canImport(Combine)
    @Published
#endif
    private var pendingServices: Set<PendingService> = []

    private var subscriptions: [Task<Void, Never>]

    public var isLoading: Bool {
        !pendingServices.isEmpty
    }

    public init(_ ctx: PartoutLoggerContext, from apis: [APIMapper], repository: APIRepository) {
        self.ctx = ctx
        self.apis = apis
        self.repository = repository
        providers = []
        cache = [:]
        subscriptions = []

        observeObjects()
    }

    public func fetchIndex() async throws {
        let service: PendingService = .index
        guard !pendingServices.contains(service) else {
            pp_log(ctx, .api, .error, "Discard fetchIndex, another .index is pending")
            return
        }
        pendingServices.insert(service)
        defer {
            pendingServices.remove(service)
        }

        var lastError: Error?
        for api in apis {
            do {
                let index = try await api.index()
                try Task.checkCancellation()
                try await repository.store(index)
#if canImport(Combine)
                objectWillChange.send()
#endif
                return
            } catch {
                lastError = error
                pp_log(ctx, .api, .error, "Unable to fetch index: \(error)")
                try Task.checkCancellation()
            }
        }
        if let lastError {
            throw lastError
        }
    }

    public func fetchInfrastructure(for providerId: ProviderID) async throws {
        let service: PendingService = .provider(providerId)
        guard !pendingServices.contains(service) else {
            pp_log(ctx, .api, .error, "Discard fetchProviderInfrastructure, another .provider(\(providerId)) is pending")
            return
        }
        pendingServices.insert(service)
        defer {
            pendingServices.remove(service)
        }

        var lastError: Error?
        for api in apis {
            do {
                let lastCache = cache[providerId]
                let infrastructure = try await api.infrastructure(for: providerId, cache: lastCache)
                try Task.checkCancellation()
                try await repository.store(infrastructure, for: providerId)
#if canImport(Combine)
                objectWillChange.send()
#endif
                return
            } catch {
                if (error as? PartoutError)?.code == .cached {
                    pp_log(ctx, .api, .info, "VPN infrastructure for \(providerId) is up to date")
                    return
                }
                lastError = error
                pp_log(ctx, .api, .error, "Unable to fetch VPN infrastructure for \(providerId): \(error)")
                try Task.checkCancellation()
            }
        }
        if let lastError {
            throw lastError
        }
    }

    public func provider(withId providerId: ProviderID) -> Provider? {
        providers.first {
            $0.id == providerId
        }
    }

    public func presets(for server: ProviderServer, moduleType: ModuleType) async throws -> [ProviderPreset] {
        try await repository.presets(for: server, moduleType: moduleType)
    }

    public func cache(for providerId: ProviderID) -> ProviderCache? {
        cache[providerId]
    }

    public func providerRepository(for providerId: ProviderID) async throws -> ProviderRepository {
        if cache(for: providerId) == nil {
            try await fetchInfrastructure(for: providerId)
        }
        return repository.providerRepository(for: providerId)
    }

    public func resetCacheForAllProviders() async {
        await repository.resetCache()
    }
}

// MARK: - Observation

private extension APIManager {
    func observeObjects() {
        subscriptions.forEach {
            $0.cancel()
        }
        subscriptions = []

        subscriptions.append(Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for await providers in repository.indexStream {
                guard !Task.isCancelled else {
                    return
                }
                self.providers = providers
            }
        })

        subscriptions.append(Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for await cache in repository.cacheStream {
                guard !Task.isCancelled else {
                    return
                }
                self.cache = cache
            }
        })
    }
}
