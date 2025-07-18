//
//  ProviderScriptingEngineTests.swift
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

@testable import Partout
import PartoutProviders
import Testing

struct ProviderScriptingEngineTests {
    @Test
    func givenEngine_whenUseAPI_thenWorks() async throws {
        let api = DefaultProviderScriptingAPI(.global, timeout: 3.0)
        let sut = api.newScriptingEngine(.global)

        let version = try await sut.execute("JSON.stringify(api.version())", after: nil, returning: Int.self)
        #expect(version == 2)

        let base64 = try await sut.execute("JSON.stringify(api.jsonToBase64({\"foo\":\"bar\"}))", after: nil, returning: String.self)
        #expect(base64 == "eyJmb28iOiJiYXIifQ==")
    }
}
