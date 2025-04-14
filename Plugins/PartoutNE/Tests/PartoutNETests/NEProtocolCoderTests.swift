//
//  NEProtocolCoderTests.swift
//  Partout
//
//  Created by Davide De Rosa on 4/13/24.
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
@testable import PartoutNE
import XCTest

final class NEProtocolCoderTests: XCTestCase {
    func test_givenProfile_whenEncodeToProvider_thenDecodes() throws {
        let profile = try newProfile()
        let sut = ProviderNEProtocolCoder(
            tunnelBundleIdentifier: bundleIdentifier,
            registry: newRegistry(),
            coder: CodableProfileCoder()
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        XCTAssertEqual(proto.providerBundleIdentifier, bundleIdentifier)
        XCTAssertNotNil(proto.providerConfiguration?[ProviderNEProtocolCoder.providerKey] as? String)

        let decodedProfile = try sut.profile(from: proto)
        XCTAssertEqual(decodedProfile, profile)
    }

    func test_givenProfile_whenEncodeToKeychain_thenDecodes() throws {
        let profile = try newProfile()
        let sut = KeychainNEProtocolCoder(
            tunnelBundleIdentifier: bundleIdentifier,
            registry: newRegistry(),
            coder: CodableProfileCoder(),
            keychain: MockKeychain()
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        XCTAssertEqual(proto.providerBundleIdentifier, bundleIdentifier)
        XCTAssertNil(proto.providerConfiguration)

        let decodedProfile = try sut.profile(from: proto)
        XCTAssertEqual(decodedProfile, profile)
    }
}

// MARK: - Helpers

private extension NEProtocolCoderTests {
    var bundleIdentifier: String {
        "com.example.MyTunnel"
    }

    func newRegistry() -> Registry {
        Registry(allHandlers: [
            DNSModule.moduleHandler,
            HTTPProxyModule.moduleHandler,
            IPModule.moduleHandler,
            OnDemandModule.moduleHandler
        ])
    }

    func newProfile() throws -> Profile {
        var builder = Profile.Builder()
        builder.name = "foobar"
        builder.modules.append(try DNSModule.Builder().tryBuild())
        builder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080, pacURLString: "http://proxy.pac").tryBuild())
        builder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).tryBuild())
        builder.modules.append(OnDemandModule.Builder().tryBuild())
        return try builder.tryBuild()
    }
}

private final class MockKeychain: Keychain {
    func set(password: String, for username: String, label: String?) throws -> Data {
        guard let reference = password.data(using: .utf8) else {
            throw PartoutError(.encoding)
        }
        return reference
    }

    func removePassword(for username: String) -> Bool {
        fatalError("Unused")
    }

    func removePassword(forReference reference: Data) -> Bool {
        fatalError("Unused")
    }

    func password(for username: String) throws -> String {
        fatalError("Unused")
    }

    func passwordReference(for username: String) throws -> Data {
        fatalError("Unused")
    }

    func allPasswordReferences() throws -> [Data] {
        fatalError("Unused")
    }

    func password(forReference reference: Data) throws -> String {
        guard let string = String(data: reference, encoding: .utf8) else {
            throw PartoutError(.decoding)
        }
        return string
    }
}
