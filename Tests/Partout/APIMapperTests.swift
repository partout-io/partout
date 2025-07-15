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

    // MARK: Authentication

    @Test(arguments: [
        MullvadAuthInput( // valid token
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        MullvadAuthInput( // no token
            accessToken: nil,
            tokenExpiryTimestamp: nil,
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        MullvadAuthInput( // expired token
            accessToken: nil,
            tokenExpiryTimestamp: "2010-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        MullvadAuthInput( // new device
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_newPublicKey",
            existingPeerId: nil,
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        ),
        MullvadAuthInput( // existing device, same public key
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_publicKey",
            existingPeerId: "test_existingPeerId",
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        ),
        MullvadAuthInput( // existing device, new public key
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_newPublicKey",
            existingPeerId: "test_existingPeerId",
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        )
    ])
    func givenMullvad_whenAuth_thenSucceeds(input: MullvadAuthInput) async throws {
        setUpLogging()

        let sut = try newAPIMapper(input.withMapper ? {
            mullvadAuthRequestMapper(for: input, method: $0, urlString: $1)
        } : nil)

        // constants
        let deviceId = "abcdef"
        let username = "1234567890"

        // input-dependent
        let tokenExpiry = input.tokenExpiryTimestamp.map {
            ISO8601DateFormatter().date(from: $0)!
        }
        let peer = input.existingPeerId.map {
            WireGuardProviderStorage.Peer(id: $0, creationDate: Date(), addresses: [])
        }
        let session = WireGuardProviderStorage.Session(privateKey: input.privateKey, publicKey: input.publicKey)
            .with(peer: peer)

        var builder = ProviderModule.Builder()
        builder.providerId = .mullvad
        builder.providerModuleType = .wireGuard
        builder.credentials = ProviderAuthentication.Credentials(username: username, password: "")
        if let accessToken = input.accessToken, let tokenExpiry {
            builder.token = ProviderAuthentication.Token(accessToken: accessToken, expiryDate: tokenExpiry)
        }

        var storage = WireGuardProviderStorage()
        storage.sessions = [deviceId: session]
        try builder.setOptions(storage, for: .wireGuard)
        let module = try builder.tryBuild()

        print("Original module: \(module)")
        let newModule = try await sut.authenticate(module, on: deviceId)
        print("Updated module: \(newModule)")

        print("Original storage: \(storage)")
        let newStorage: WireGuardProviderStorage = try #require(try newModule.options(for: .wireGuard))
        print("Updated storage: \(newStorage)")

        // assert token reuse or renewal
        let newToken = ProviderAuthentication.Token(
            accessToken: "test_newToken",
            expiryDate: ISO8601DateFormatter().date(from: "2025-07-13T23:38:33+00:00")!
        )
        if let tokenExpiry {
            if tokenExpiry > Date() {
                #expect(newModule.authentication?.token?.accessToken == input.accessToken)
                #expect(newModule.authentication?.token?.expiryDate == tokenExpiry)
            } else {
                #expect(newModule.authentication?.token == newToken)
            }
        } else {
            #expect(newModule.authentication?.token == newToken)
        }

        // assert device lookup or creation
        let newSession = try #require(newStorage.sessions?[deviceId])
        if let peerId = input.existingPeerId {
            #expect(newSession.peer?.id == peerId)
        } else {
            #expect(newSession.peer?.id == "test_newPeerId")
        }

        // assert public key update
        #expect(newSession.publicKey == input.publicKey)

        // assert addresses
        if let peerAddresses = input.peerAddresses {
            #expect(newSession.peer?.addresses == peerAddresses)
        }
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
    struct MullvadAuthInput {
        let accessToken: String?

        let tokenExpiryTimestamp: String?

        let privateKey: String

        let publicKey: String

        let existingPeerId: String?

        var peerAddresses: [String]?

        var withMapper = true
    }

    func mullvadAuthRequestMapper(for input: MullvadAuthInput, method: String, urlString: String) -> (Int, Data) {
        var filename: String?
        var httpStatus: Int?
        if urlString.contains("/devices") {
            if method == "GET" {
                filename = "get-devices"
                httpStatus = 200
            } else if method == "POST" {
                filename = "post-device"
                httpStatus = 201
            } else if method == "PUT" {
                filename = "put-device"
                httpStatus = 200
            }
        } else if urlString.hasSuffix("/token") {
            filename = "post-auth"
            httpStatus = 200
        }
        guard let filename, let httpStatus else {
            fatalError("Unmapped request: \(method) \(urlString)")
        }
        guard let url = Bundle.module.url(forResource: "Resources/mullvad/\(filename)", withExtension: "json") else {
            fatalError("Unable to find \(filename).json")
        }
        print("Original: \(method) \(urlString)")
        print("Mapped: \(url)")
        do {
            var json = try String(contentsOf: url)

            // simulate POST/PUT update to new public key
            if method != "GET", urlString.contains("/devices") {
                json = json.replacingOccurrences(of: "test_publicKey", with: input.publicKey)
            }
            guard let data = json.data(using: .utf8) else {
                fatalError("Unable to encode JSON")
            }
            return (httpStatus, data)
        } catch {
            fatalError("Unable to read JSON contents: \(error)")
        }
    }

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
