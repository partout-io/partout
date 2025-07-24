//
//  APITestSuite.swift
//  Partout
//
//  Created by Davide De Rosa on 7/16/25.
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
@testable import Partout
import PartoutCore
@testable import PartoutProviders

protocol APITestSuite {
}

extension APITestSuite {
    func newAPIMapper(_ requestHijacker: ((String, String) -> (Int, Data))? = nil) throws -> APIMapper {
        guard let baseURL = API.url() else {
            fatalError("Could not find resource path")
        }
        return DefaultAPIMapper(
            .global,
            baseURL: baseURL,
            timeout: 3.0,
            api: DefaultProviderScriptingAPI(
                .global,
                timeout: 3.0,
                requestHijacker: requestHijacker
            )
        )
    }

    func setUpLogging() {
        var logger = PartoutLogger.Builder()
#if canImport(OSLog)
        logger.setDestination(OSLogDestination(.api), for: [.api])
        logger.setDestination(OSLogDestination(.providers), for: [.providers])
#endif
        PartoutLogger.register(logger.build())
    }

    func measureFetchProvider() async throws {
        let sut = try newAPIMapper()
        let begin = Date()
        for _ in 0..<1000 {
            let module = try ProviderModule(emptyWithProviderId: .hideme)
            _ = try await sut.infrastructure(for: module, cache: nil)
        }
        print("Elapsed: \(-begin.timeIntervalSinceNow)")
    }
}
