//
//  DefaultAPIMapper.swift
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

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PartoutAPI
import PartoutCore

public final class DefaultAPIMapper: APIMapper {
    private let ctx: PartoutLoggerContext

    private let baseURL: URL

    private let timeout: TimeInterval

    private let api: ProviderScriptingAPI

    private let engineFactory: (ProviderScriptingAPI) -> ScriptingEngine

    public init(
        _ ctx: PartoutLoggerContext,
        baseURL: URL,
        timeout: TimeInterval = 10.0,
        api: ProviderScriptingAPI,
        engineFactory: @escaping (ProviderScriptingAPI) -> ScriptingEngine
    ) {
        self.ctx = ctx
        self.baseURL = baseURL
        self.timeout = timeout
        self.api = api
        self.engineFactory = engineFactory
    }

    public func index() async throws -> [Provider] {
        let data = try await data(for: .index)
        let json = try JSONDecoder().decode(API.REST.Index.self, from: data)

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
#if canImport(_PartoutWireGuardCore)
        case .wireGuard:

            // preconditions (also check in script)
            guard let auth = module.authentication, !auth.isEmpty else {
                throw PartoutError(.authentication)
            }
            guard let storage: WireGuardProviderStorage = try module.options(for: .wireGuard) else {
                throw PartoutError(.Providers.missingOption)
            }
            guard storage.sessions?[deviceId] != nil else {
                throw PartoutError(.Providers.missingOption)
            }

            let script = try await script(for: .provider(module.providerId))
            let engine = engineFactory(api)
            return try await engine.authenticate(ctx, module, on: deviceId, with: script)
#endif
        default:
            assertionFailure("Authentication not supported for module type \(module.providerModuleType)")
            return module
        }
    }

    public func infrastructure(for providerId: ProviderID, cache: ProviderCache?) async throws -> ProviderInfrastructure {
        let script = try await script(for: .provider(providerId))
        let engine = engineFactory(api)
        return try await engine.fetchInfrastructure(ctx, with: script, cache: cache)
    }
}

// MARK: - Engine

// TODO: #54/partout, assumes engine to be JavaScript
extension ScriptingEngine {
    func authenticate(_ ctx: PartoutLoggerContext, _ module: ProviderModule, on deviceId: String, with script: String) async throws -> ProviderModule {
        let moduleData = try JSONEncoder().encode(module)
        guard let moduleJSON = String(data: moduleData, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        let result = try await execute(
            "JSON.stringify(authenticate(JSON.parse('\(moduleJSON.jsEscaped)'), '\(deviceId)'))",
            after: script,
            returning: ScriptResult<ProviderModule>.self
        )
        if let error = result.error {
            throw PartoutError(.scriptException, error)
        }
        guard let response = result.response else {
            throw PartoutError(.scriptException, result.error ?? "unknown")
        }
        return response
    }

    func fetchInfrastructure(_ ctx: PartoutLoggerContext, with script: String, cache: ProviderCache?) async throws -> ProviderInfrastructure {
        var headers: [String: String] = [:]
        if let lastUpdate = cache?.lastUpdate {
            headers["If-Modified-Since"] = lastUpdate.toRFC1123()
        }
        if let tag = cache?.tag {
            headers["If-None-Match"] = tag
        }
        let headersData = try JSONEncoder().encode(headers)
        guard let headersJSON = String(data: headersData, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        pp_log(ctx, .api, .debug, "Headers: \(headersJSON)")
        pp_log(ctx, .api, .debug, "Headers (escaped): \(headersJSON.jsEscaped)")
        let result = try await execute(
            "JSON.stringify(getInfrastructure(JSON.parse('\(headersJSON.jsEscaped)')))",
            after: script,
            returning: ScriptResult<ProviderInfrastructure>.self
        )
        guard let response = result.response else {
            if let error = result.error {
                throw PartoutError(.scriptException, error)
            }
            // XXX: empty response without error = cached response
            else {
                throw PartoutError(.cached)
            }
        }
        return response
    }
}

// MARK: - Helpers

private extension String {
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension DefaultAPIMapper {
    func script(for resource: API.REST.Resource) async throws -> String {
        let data = try await data(for: resource)
        guard let script = String(data: data, encoding: .utf8) else {
            throw PartoutError(.notFound)
        }
        return script
    }

    func data(for resource: API.REST.Resource) async throws -> Data {
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

// JS -> Swift
private struct ScriptResult<T>: Decodable where T: Decodable {
    let response: T?

    let error: String?
}
