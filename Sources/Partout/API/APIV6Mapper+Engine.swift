//
//  APIV6Mapper+Engine.swift
//  Partout
//
//  Created by Davide De Rosa on 3/27/25.
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
    final class DefaultScriptExecutor {
        private let ctx: PartoutContext

        // override the URL for getText/getJSON
        private let resultURL: URL?

        private let cache: ProviderCache?

        private let timeout: TimeInterval

        private let engine: APIScriptingEngine

        init(_ ctx: PartoutContext, resultURL: URL?, cache: ProviderCache?, timeout: TimeInterval, engine: APIScriptingEngine) {
            self.ctx = ctx
            self.resultURL = resultURL
            self.cache = cache
            self.timeout = timeout
            self.engine = engine

            // inject virtual machine functions in the engine-specific way
            engine.inject(from: self)
        }
    }
}

// MARK: - ScriptExecutor

extension API.V6.DefaultScriptExecutor: APIEngine.ScriptExecutor {
    func fetchInfrastructure(with script: String) async throws -> ProviderInfrastructure {
        // TODO: #54/partout, assumes engine to be JavaScript
        let result = try await engine.execute(
            "JSON.stringify(getInfrastructure())",
            after: script,
            returning: APIEngine.ScriptResult<ProviderInfrastructure>.self
        )
        guard let response = result.response else {
            switch result.error {
            case .cached:
                throw PartoutError(.cached)
            default:
                throw PartoutError(.scriptException, result.error?.rawValue ?? "unknown")
            }
        }
        return response
    }
}

// MARK: - VirtualMachine

extension API.V6.DefaultScriptExecutor: APIEngine.VirtualMachine {
    private final class ResultStorage: @unchecked Sendable {
        var textData: Data?

        var lastModified: Date?

        var tag: String?

        var isCached = false
    }

    func getResult(urlString: String) -> APIEngine.GetResult {
        pp_log(ctx, .api, .info, "JS.getResult: Execute with URL: \(resultURL?.absoluteString ?? urlString)")
        guard let url = resultURL ?? URL(string: urlString) else {
            return APIEngine.GetResult(.url)
        }

        // use external caching (e.g. Core Data)
        let cfg: URLSessionConfiguration = .ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)

        var request = URLRequest(url: url)
        if let lastUpdate = cache?.lastUpdate {
            request.setValue(lastUpdate.toRFC1123(), forHTTPHeaderField: "If-Modified-Since")
        }
        if let tag = cache?.tag {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        pp_log(ctx, .api, .info, "JS.getResult: GET \(url)")
        if let headers = request.allHTTPHeaderFields {
            pp_log(ctx, .api, .info, "JS.getResult: Headers: \(headers)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let storage = ResultStorage()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                return
            }
            if let error {
                pp_log(ctx, .api, .error, "JS.getResult: Unable to execute: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse {
                let lastModifiedHeader = httpResponse.value(forHTTPHeaderField: "last-modified")
                let tag = httpResponse.value(forHTTPHeaderField: "etag")

                pp_log(ctx, .api, .debug, "JS.getResult: Response: \(httpResponse)")
                pp_log(ctx, .api, .info, "JS.getResult: HTTP \(httpResponse.statusCode)")
                if let lastModifiedHeader {
                    pp_log(ctx, .api, .info, "JS.getResult: Last-Modified: \(lastModifiedHeader)")
                    storage.lastModified = lastModifiedHeader.fromRFC1123()
                }
                if let tag {
                    pp_log(ctx, .api, .info, "JS.getResult: ETag: \(tag)")
                    storage.tag = tag
                }
                storage.isCached = httpResponse.statusCode == 304
            }
            storage.textData = data
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let textData = storage.textData else {
            pp_log(ctx, .api, .error, "JS.getResult: Empty response")
            return APIEngine.GetResult(.network)
        }
        pp_log(ctx, .api, .info, "JS.getResult: Success (cached: \(storage.isCached))")
        return APIEngine.GetResult(
            textData,
            lastModified: storage.lastModified,
            tag: storage.tag,
            isCached: storage.isCached
        )
    }

    func getText(urlString: String) -> [String: Any] {
        let textResult = {
            let result = getResult(urlString: urlString)
            if result.isCached {
                return APIEngine.GetResult(.cached)
            }
            guard let text = result.response as? Data else {
                pp_log(ctx, .api, .error, "JS.getText: Response is not Data")
                return APIEngine.GetResult(.network)
            }
            guard let string = String(data: text, encoding: .utf8) else {
                pp_log(ctx, .api, .error, "JS.getText: Response is not String")
                return APIEngine.GetResult(.network)
            }
            return result.with(response: string)
        }()
        return textResult.serialized()
    }

    func getJSON(urlString: String) -> [String: Any] {
        let jsonResult = {
            let result = getResult(urlString: urlString)
            if result.isCached {
                return APIEngine.GetResult(.cached)
            }
            guard let text = result.response as? Data else {
                pp_log(ctx, .api, .error, "JS.getJSON: Response is not Data")
                return APIEngine.GetResult(.network)
            }
            do {
                let object = try JSONSerialization.jsonObject(with: text)
                return result.with(response: object)
            } catch {
                pp_log(ctx, .api, .error, "JS.getJSON: Unable to parse JSON: \(error)")
                return APIEngine.GetResult(.parsing)
            }
        }()
        return jsonResult.serialized()
    }

    func jsonToBase64(object: Any) -> String? {
        do {
            return try JSONSerialization.data(withJSONObject: object)
                .base64EncodedString()
        } catch {
            pp_log(ctx, .api, .error, "JS.jsonToBase64: Unable to serialize: \(error)")
            return nil
        }
    }

    func ipV4ToBase64(ip: String) -> String? {
        let bytes = ip
            .split(separator: ".")
            .compactMap {
                UInt8($0)
            }
        guard bytes.count == 4 else {
            pp_log(ctx, .api, .error, "JS.ipV4ToBase64: Not a IPv4 string")
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
    }

    func openVPNTLSWrap(strategy: String, file: String) -> [String: Any]? {
        let hex = file
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .joined()
        let key = Data(hex: hex)
        guard key.count == 256 else {
            pp_log(ctx, .api, .error, "JS.openVPNTLSWrap: Static key must be 64 bytes long")
            return nil
        }
        return [
            "strategy": strategy,
            "key": [
                "dir": 1,
                "data": key.base64EncodedString()
            ]
        ]
    }

    func debug(message: String) {
        pp_log(ctx, .api, .debug, message)
    }
}

#endif
