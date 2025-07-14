//
//  APIEngine.swift
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

import Foundation
import PartoutCore
import PartoutProviders

public protocol APIScriptingEngine: ScriptingEngine {
    func inject(from vm: APIEngine.VirtualMachine)
}

public enum APIEngine {
    public protocol ScriptExecutor {
        func authenticate(_ module: ProviderModule, on deviceId: String, with script: String) async throws -> ProviderModule

        func fetchInfrastructure(with script: String) async throws -> ProviderInfrastructure
    }

    public protocol VirtualMachine {
        func getResult(
            method: String,
            urlString: String,
            headers: [String: String]?,
            body: String?
        ) -> [String: Any]

        func getText(urlString: String) -> [String: Any]

        func getJSON(urlString: String) -> [String: Any]

        func jsonFromBase64(string: String) -> Any?

        func jsonToBase64(object: Any) -> String?

        func timestampFromISO(isoString: String) -> Int

        func timestampToISO(timestamp: Int) -> String

        func ipV4ToBase64(ip: String) -> String?

        func openVPNTLSWrap(strategy: String, file: String) -> [String: Any]?

        func debug(message: String)

        func errorResponse(message: String) -> [String: Any]
    }
}

extension APIEngine.VirtualMachine {
    public func httpErrorResponse(status: Int, urlString: String) -> [String: Any] {
        errorResponse(message: "HTTP \(status) \(urlString)")
    }
}

extension APIEngine {

    // Swift -> JS
    public struct GetResult {
        public private(set) var response: Any?

        public let error: String?

        // extra

        public let status: Int?

        public let lastModified: Date?

        public let tag: String?

        public let isCached: Bool

        public init(_ response: Any, status: Int?, lastModified: Date?, tag: String?, isCached: Bool = false) {
            self.response = response
            error = nil

            self.status = status
            self.lastModified = lastModified
            self.tag = tag
            self.isCached = isCached
        }

        public init(_ error: String) {
            response = nil
            self.error = error

            status = nil
            lastModified = nil
            tag = nil
            isCached = false
        }

        public func with(response: Any) -> Self {
            var copy = self
            copy.response = response
            return copy
        }

        public func serialized() -> [String: Any] {
            var map: [String: Any] = [:]
            if let response {
                map["response"] = response
                if let status {
                    map["status"] = status
                }

                // follow ProviderCache
                var cache: [String: Any] = [:]
                cache["lastUpdate"] = (lastModified ?? Date()).timeIntervalSinceReferenceDate
                if let tag {
                    cache["tag"] = tag
                }
                map["cache"] = cache

                map["isCached"] = isCached
            }
            if let error {
                map["error"] = error
            }
            return map
        }
    }

    // JS -> Swift
    public struct ScriptResult<T>: Decodable where T: Decodable {
        public let response: T?

        public let error: String?
    }
}
