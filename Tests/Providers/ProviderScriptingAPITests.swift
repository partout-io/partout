//
//  ProviderScriptingAPITests.swift
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

import Foundation
@testable import PartoutProviders
import Testing

struct ProviderScriptingAPITests {

    @Test
    func givenScriptResult_whenHasCache_thenReturnsProviderCache() throws {
        let date = Timestamp.now()
        let tag = "12345"
        let sut = ProviderScriptResult("", status: nil, lastModified: date, tag: tag)

        let object = try #require(sut.serialized()["cache"])
        let data = try JSONSerialization.data(withJSONObject: object)
        let cache = try JSONDecoder().decode(ProviderCache.self, from: data)

        #expect(cache.lastUpdate == date)
        #expect(cache.tag == tag)
    }

    @Test
    func givenAPI_whenProviderGetResult_thenIsMapped() {
        let sut = DefaultProviderScriptingAPI(.global, timeout: 3.0) {
            #expect($0 == "GET")
            #expect($1 == "doesntmatter")
            do {
                let url = try #require(Bundle.module.url(forResource: "mapped", withExtension: "txt"))
                let data = try Data(contentsOf: url)
                return (200, data)
            } catch {
                fatalError("Unable to return bundle resource: \(error)")
            }
        }
        let map = sut.getText(urlString: "doesntmatter", headers: nil)
        #expect(map["response"] as? String == "mapped content\n")
    }

    @Test(arguments: [
        (1752562800, "Tue, 15 Jul 2025 07:00:00 GMT"),
        (1698907632, "Thu, 02 Nov 2023 06:47:12 GMT")
    ])
    func givenTimestamp_whenGetRFC1123_thenIsExpected(timestamp: Timestamp, rfc: String) {
        #expect(timestamp.toRFC1123() == rfc)
        #expect(rfc.fromRFC1123() == timestamp)
    }
}
