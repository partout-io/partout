//
//  InMemoryAPIRepository.swift
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

public final class InMemoryAPIRepository: APIRepositoryReader, APIRepositoryWriter {
    private let providersSubject: CurrentValueStream<[Provider]>

    private let infrastructuresSubject: CurrentValueStream<[ProviderID: ProviderInfrastructure]>

    public init() {
        providersSubject = CurrentValueStream([])
        infrastructuresSubject = CurrentValueStream([:])
    }

    // MARK: ProviderRepositoryReader

    public var indexStream: AsyncStream<[Provider]> {
        providersSubject.subscribe()
    }

    public var cacheStream: AsyncStream<[ProviderID: ProviderCache]> {
        infrastructuresSubject
            .subscribe()
            .map {
                $0.compactMapValues(\.cache)
            }
    }

    public func presets(for server: ProviderServer, moduleType: ModuleType) async throws -> [ProviderPreset] {
        guard let infra = infrastructuresSubject.value[server.metadata.providerId] else {
            return []
        }
        if let supported = server.supportedPresetIds {
            return infra.presets.filter {
                supported.contains($0.presetId)
            }
        }
        return infra.presets
    }

    public func providerRepository(for providerId: ProviderID) -> ProviderRepository {
        let infra = infrastructuresSubject.value[providerId]
        let servers = infra?.servers ?? []
        let presets = infra?.presets ?? []
        return InMemoryProviderRepository(
            providerId: providerId,
            allPresets: presets,
            allServers: servers
        )
    }

    // MARK: ProviderRepositoryWriter

    public func store(_ providers: [Provider]) {
        providersSubject.send(providers)
    }

    public func store(_ infrastructure: ProviderInfrastructure, for providerId: ProviderID) {
        if let newDate = infrastructure.cache?.lastUpdate,
           let currentDate = infrastructuresSubject.value[providerId]?.cache?.lastUpdate {
            guard newDate > currentDate else {
                pp_log(.api, .info, "Discard infrastructure older than stored one (\(newDate) <= \(currentDate))")
                return
            }
        }
        var newValue = infrastructuresSubject.value
        newValue[providerId] = infrastructure
        infrastructuresSubject.send(newValue)
    }

    public func resetCache(for providerIds: [ProviderID]?) async {
        if let providerIds {
            let newValue = infrastructuresSubject.value
                .filter {
                    !providerIds.contains($0.key)
                }
            infrastructuresSubject.send(newValue)
            return
        }
        infrastructuresSubject.send([:])
    }
}
