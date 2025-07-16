//
//  APIMapperTests.swift
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

#if canImport(PartoutAPI)

@testable import Partout
@testable import PartoutProviders
import Testing

struct APIMapperTests {

    // MARK: Index

    @Test
    func whenFetchIndex_thenReturnsProviders() async throws {
        setUpLogging()

        let sut = try newAPIMapper()
        let index = try await sut.index()
        #expect(index.count == 12)
        #expect(index.map(\.description) == [
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

    // MARK: Infrastructures

    @Test(arguments: [
        HideMeFetchInput(
            cache: nil,
            presetsCount: 1,
            serversCount: 2,
            isCached: false
        ),
//        HideMeFetchInput(
//            cache: nil,
//            presetsCount: 1,
//            serversCount: 99,
//            isCached: false,
//            hijacking: false
//        ),
//        HideMeFetchInput(
//            cache: ProviderCache(lastUpdate: nil, tag: "\\\"0103dd09364f346ff8a8c2b9d5285b5d\\\""),
//            presetsCount: 1,
//            serversCount: 99,
//            isCached: true,
//            hijacking: false
//        )
    ])
    func givenHideMe_whenFetchInfrastructure_thenReturns(input: HideMeFetchInput) async throws {
        setUpLogging()

        let sut = try newAPIMapper(input.hijacking ? {
            hidemeFetchHijacker(urlString: $1)
        } : nil)
        do {
            let infra = try await sut.infrastructure(for: .hideme, cache: input.cache)
            #expect(infra.presets.count == input.presetsCount)
            #expect(infra.servers.count == input.serversCount)

#if canImport(_PartoutOpenVPNCore)
            try infra.presets.forEach {
                let template = try JSONDecoder().decode(OpenVPNProviderTemplate.self, from: $0.templateData)
                switch $0.presetId {
                case "default":
                    #expect(template.configuration.cipher == .aes256cbc)
                    #expect(template.endpoints.map(\.rawValue) == [
                        "UDP:3000", "UDP:3010", "UDP:3020", "UDP:3030", "UDP:3040", "UDP:3050",
                        "UDP:3060", "UDP:3070", "UDP:3080", "UDP:3090", "UDP:3100",
                        "TCP:3000", "TCP:3010", "TCP:3020", "TCP:3030", "TCP:3040", "TCP:3050",
                        "TCP:3060", "TCP:3070", "TCP:3080", "TCP:3090", "TCP:3100"
                    ])
                default:
                    break
                }
            }
#endif
        } catch let error as PartoutError {
            if input.isCached {
                #expect(error.code == .cached)
            } else {
                #expect(Bool(false), "Failed: \(error)")
            }
        } catch {
            #expect(Bool(false), "Failed: \(error)")
        }
    }
}

// MARK: - Hijackers

extension APIMapperTests {
    struct HideMeFetchInput {
        let cache: ProviderCache?

        let presetsCount: Int

        let serversCount: Int

        let isCached: Bool

        var hijacking = true
    }

    func hidemeFetchHijacker(urlString: String) -> (Int, Data) {
        guard let url = Bundle.module.url(forResource: "Resources/hideme/fetch", withExtension: "json") else {
            fatalError("Unable to find fetch.json")
        }
        do {
            let data = try Data(contentsOf: url)
            return (200, data)
        } catch {
            fatalError("Unable to read JSON contents: \(error)")
        }
    }
}

// MARK: - Helpers

private extension APIMapperTests {
    func newAPIMapper(_ requestHijacker: ((String, String) -> (Int, Data))? = nil) throws -> APIMapper {
        guard let baseURL = API.bundleURL else {
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
        logger.setDestination(OSLogDestination(.api), for: [.api])
        logger.setDestination(OSLogDestination(.providers), for: [.providers])
        PartoutLogger.register(logger.build())
    }

    func measureFetchProvider() async throws {
        let sut = try newAPIMapper()
        let begin = Date()
        for _ in 0..<1000 {
            _ = try await sut.infrastructure(for: .hideme, cache: nil)
        }
        print("Elapsed: \(-begin.timeIntervalSinceNow)")
    }
}

#endif
