// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import Partout
@testable import PartoutProviders
import Testing

struct MullvadProviderTests: APITestSuite {
    init() {
        setUpLogging()
    }

#if PARTOUT_WIREGUARD
    @Test(arguments: [
        AuthInput( // valid token
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        AuthInput( // no token
            accessToken: nil,
            tokenExpiryTimestamp: nil,
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        AuthInput( // expired token
            accessToken: nil,
            tokenExpiryTimestamp: "2010-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_existingPublicKey",
            existingPeerId: "test_existingPeerId"
        ),
        AuthInput( // new device
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_newPublicKey",
            existingPeerId: nil,
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        ),
        AuthInput( // existing device, same public key
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_publicKey",
            existingPeerId: "test_existingPeerId",
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        ),
        AuthInput( // existing device, new public key
            accessToken: "sometoken",
            tokenExpiryTimestamp: "2100-01-01T14:42:07+00:00",
            privateKey: "dummyPrivateKey",
            publicKey: "test_newPublicKey",
            existingPeerId: "test_existingPeerId",
            peerAddresses: ["10.10.10.10/32", "fc00::10/128"]
        )
    ])
    func whenAuth_thenSucceeds(input: AuthInput) async throws {
        let sut = try newAPIMapper(input.hijacked ? { @Sendable in
            hijacker(for: input, method: $0, urlString: $1)
        } : nil)

        // constants
        let deviceId = "abcdef"
        let username = "1234567890"

        // input-dependent
        let tokenExpiry = input.tokenExpiryTimestamp.map {
            ISO8601DateFormatter().date(from: $0)!
        }

        var builder = ProviderModule.Builder()
        builder.providerId = .mullvad
        builder.credentials = ProviderAuthentication.Credentials(username: username, password: "")
        if let accessToken = input.accessToken, let tokenExpiry {
            builder.token = ProviderAuthentication.Token(accessToken: accessToken, expiryDate: tokenExpiry)
        }

        builder.providerModuleType = .wireGuard

        let peer = input.existingPeerId.map {
            WireGuardProviderStorage.Peer(id: $0, creationDate: Date(), addresses: [])
        }
        let session = WireGuardProviderStorage.Session(privateKey: input.privateKey, publicKey: input.publicKey)
            .with(peer: peer)

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
#endif
}

extension MullvadProviderTests {
    struct AuthInput {
        let accessToken: String?

        let tokenExpiryTimestamp: String?

        let privateKey: String

        let publicKey: String

        let existingPeerId: String?

        var peerAddresses: [String]?

        var hijacked = true
    }

    func hijacker(for input: AuthInput, method: String, urlString: String) -> (Int, Data) {
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
}
