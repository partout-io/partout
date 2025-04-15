//
//  APIV6MapperTests.swift
//  Partout
//
//  Created by Davide De Rosa on 1/14/25.
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
import PartoutAPI
import PartoutCore
import PartoutSupport
import XCTest

final class APIV6MapperTests: XCTestCase {

    // MARK: Index

    func test_givenAPI_whenFetchIndex_thenReturnsProviders() async throws {
        let sut = try Self.apiV6()
        let index = try await sut.index()
        XCTAssertEqual(index.count, 12)
        XCTAssertEqual(index.map(\.description), [
            "Hide.me",
            "IVPN",
            "Mullvad",
            "NordVPN",
            "Oeck",
            "PIA",
            "ProtonVPN",
            "SurfShark",
            "TorGuard",
            "TunnelBear",
            "VyprVPN",
            "Windscribe"
        ])
    }

    // MARK: Providers

    func test_givenAPI_whenFetchHideMe_thenReturnsInfrastructure() async throws {
        let sut = try Self.apiV6()
        do {
            let infra = try await sut.infrastructure(for: .hideme, cache: nil)
            XCTAssertEqual(infra.presets.count, 1)
            XCTAssertEqual(infra.servers.count, 2)

            try infra.presets.forEach {
                let template = try JSONDecoder().decode(OpenVPNProviderTemplate.self, from: $0.templateData)
                switch $0.presetId {
                case "default":
                    XCTAssertEqual(template.configuration.cipher, .aes256cbc)
                    XCTAssertEqual(template.endpoints.map(\.rawValue), [
                        "UDP:3000", "UDP:3010", "UDP:3020", "UDP:3030", "UDP:3040", "UDP:3050",
                        "UDP:3060", "UDP:3070", "UDP:3080", "UDP:3090", "UDP:3100",
                        "TCP:3000", "TCP:3010", "TCP:3020", "TCP:3030", "TCP:3040", "TCP:3050",
                        "TCP:3060", "TCP:3070", "TCP:3080", "TCP:3090", "TCP:3100"
                    ])
                default:
                    break
                }
            }
        } catch {
            XCTFail("Failed: \(error)")
        }
    }

    func test_givenGetResult_whenHasCache_thenReturnsProviderCache() throws {
        let date = Date()
        let tag = "12345"
        let sut = APIEngine.GetResult("", lastModified: date, tag: tag)

        let object = try XCTUnwrap(sut.serialized()["cache"])
        let data = try JSONSerialization.data(withJSONObject: object)
        let cache = try JSONDecoder().decode(ProviderCache.self, from: data)

        XCTAssertEqual(cache.lastUpdate, date)
        XCTAssertEqual(cache.tag, tag)
    }

    // MARK: -

    func test_measureFetchProvider() async throws {
        let sut = try Self.apiV6()
        let begin = Date()
        for _ in 0..<1000 {
            _ = try await sut.infrastructure(for: .hideme, cache: nil)
        }
        print("Elapsed: \(-begin.timeIntervalSinceNow)")
    }
}

private extension APIV6MapperTests {
    static func apiV6() throws -> APIMapper {
        let root = "Resources/API/v6"
        guard let baseURL = Bundle.module.url(forResource: root, withExtension: nil) else {
            fatalError("Could not find resource path")
        }
        let infrastructureURL: (ProviderID) -> URL = {
            baseURL.appendingPathComponent("providers/\($0.rawValue)/fetch.json")
        }
        return API.V6.Mapper(
            baseURL: baseURL,
            infrastructureURL: infrastructureURL
        )
    }
}
