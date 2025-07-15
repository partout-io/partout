//
//  ProviderScriptingAPI.swift
//  Partout
//
//  Created by Davide De Rosa on 7/15/25.
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

public protocol ProviderScriptingAPI {
    func getResult(
        method: String,
        urlString: String,
        headers: [String: String]?,
        body: String?
    ) -> [String: Any]

    func getText(urlString: String, headers: [String: String]?) -> [String: Any]

    func getJSON(urlString: String, headers: [String: String]?) -> [String: Any]

    func jsonFromBase64(string: String) -> Any?

    func jsonToBase64(object: Any) -> String?

    func timestampFromISO(isoString: String) -> Int

    func timestampToISO(timestamp: Int) -> String

    func ipV4ToBase64(ip: String) -> String?

    func openVPNTLSWrap(strategy: String, file: String) -> [String: Any]?

    func errorResponse(message: String) -> [String: Any]

    func debug(message: String)
}

extension ProviderScriptingAPI {
    public func httpErrorResponse(status: Int, urlString: String) -> [String: Any] {
        errorResponse(message: "HTTP \(status) \(urlString)")
    }
}
