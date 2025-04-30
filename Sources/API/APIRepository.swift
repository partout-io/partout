//
//  APIRepository.swift
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

public typealias APIRepository = APIRepositoryReader & APIRepositoryWriter

public protocol APIRepositoryReader {
    var indexStream: AsyncStream<[Provider]> { get }

    var cacheStream: AsyncStream<[ProviderID: ProviderCache]> { get }

    func presets(for server: ProviderServer, moduleType: ModuleType) async throws -> [ProviderPreset]

    func providerRepository(for providerId: ProviderID) -> ProviderRepository
}

public protocol APIRepositoryWriter {
    func store(_ index: [Provider]) async throws

    func store(_ infrastructure: ProviderInfrastructure, for providerId: ProviderID) async throws

    func resetCache(for providerIds: [ProviderID]?) async
}

extension APIRepositoryWriter {
    public func resetCache() async {
        await resetCache(for: nil)
    }
}
