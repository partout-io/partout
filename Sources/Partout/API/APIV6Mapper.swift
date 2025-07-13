//
//  APIV6Mapper.swift
//  Partout
//
//  Created by Davide De Rosa on 3/25/25.
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

#if canImport(PartoutAPI)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PartoutAPI
import PartoutCore

extension API.V6 {
    public final class Mapper: APIMapper {
        private let ctx: PartoutLoggerContext

        private let baseURL: URL

        private let infrastructureURL: ((ProviderID) -> URL)?

        private let timeout: TimeInterval

        private let executorFactory: (URL?, ProviderCache?, TimeInterval) -> APIEngine.ScriptExecutor

        public init(
            _ ctx: PartoutLoggerContext,
            baseURL: URL,
            infrastructureURL: ((ProviderID) -> URL)? = nil,
            timeout: TimeInterval = 10.0,
            executorFactory: @escaping (URL?, ProviderCache?, TimeInterval) -> APIEngine.ScriptExecutor
        ) {
            self.ctx = ctx
            self.baseURL = baseURL
            self.infrastructureURL = infrastructureURL
            self.timeout = timeout
            self.executorFactory = executorFactory
        }

        public func index() async throws -> [Provider] {
            let data = try await data(for: .index)
            let json = try JSONDecoder().decode(API.V6.Index.self, from: data)

            return json
                .providers
                .map {
                    let metadata = $0.metadata.reduce(into: [:]) {
                        $0[ModuleType($1.key)] = Provider.Metadata(userInfo: $1.value)
                    }
                    return Provider(
                        $0.id.rawValue,
                        description: $0.description,
                        metadata: metadata
                    )
                }
        }

        public func authenticate(_ module: ProviderModule, on deviceId: String) async throws -> ProviderModule {
            switch module.providerModuleType {
            case .wireGuard:
                guard let options: WireGuardProviderTemplate.Options = try module.options(for: .wireGuard) else {
                    throw PartoutError(.Providers.missingProviderOption)
                }
                guard options.sessions?[deviceId] != nil else {
                    throw PartoutError(.Providers.missingProviderOption)
                }
                let data = try await data(for: .providerAuth(module.providerId))
                guard let script = String(data: data, encoding: .utf8) else {
                    throw PartoutError(.notFound)
                }
                let executor = executorFactory(nil, nil, timeout)
                return try await executor.authenticate(module, on: deviceId, with: script)
            default:
                fatalError("Authentication not supported for module type \(module.providerModuleType)")
            }
        }

        public func infrastructure(for providerId: ProviderID, cache: ProviderCache?) async throws -> ProviderInfrastructure {
            let data = try await data(for: .providerInfrastructure(providerId))
            guard let script = String(data: data, encoding: .utf8) else {
                throw PartoutError(.notFound)
            }
            let resultURL = infrastructureURL?(providerId)
            let executor = executorFactory(resultURL, cache, timeout)
            return try await executor.fetchInfrastructure(with: script)
        }
    }
}

private extension API.V6.Mapper {
    func data(for resource: API.V6.Resource) async throws -> Data {
        let url = baseURL.appendingPathComponent(resource.path)
        pp_log(ctx, .api, .info, "Fetch data for \(resource): \(url)")
        let cfg: URLSessionConfiguration = .default
        cfg.requestCachePolicy = .reloadRevalidatingCacheData
        cfg.urlCache = .shared
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        let request = URLRequest(url: url)
        do {
            let result = try await session.data(for: request)
            if URLCache.shared.cachedResponse(for: request) != nil {
                pp_log(ctx, .api, .info, "Data was cached: \(url)")
            }
            return result.0
        } catch {
            pp_log(ctx, .api, .error, "Unable to fetch data: \(url), \(error)")
            throw error
        }
    }
}

#endif
