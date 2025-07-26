// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout
import XCTest

#if canImport(PartoutOpenVPN)
import PartoutOpenVPN
#endif
#if canImport(PartoutWireGuard)
import PartoutWireGuard
#endif
import PartoutCore

final class RegistryTests: XCTestCase {

#if canImport(PartoutOpenVPN) && canImport(PartoutWireGuard)
    func test_givenKnownHandlers_whenSerializeProfile_thenIsDeserialized() throws {
        let sut = Registry()

        var ovpnBuilder = OpenVPN.Configuration.Builder()
        ovpnBuilder.ca = OpenVPN.CryptoContainer(pem: "ca is required")
        ovpnBuilder.cipher = .aes128cbc
        ovpnBuilder.remotes = [
            try XCTUnwrap(.init("host.name", .init(.tcp, 80)))
        ]

        let wgBuilder = WireGuard.Configuration.Builder(privateKey: "")

        var profileBuilder = Profile.Builder()
        profileBuilder.modules.append(try DNSModule.Builder().tryBuild())
        profileBuilder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).tryBuild())
        profileBuilder.modules.append(OnDemandModule.Builder().tryBuild())
        profileBuilder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080).tryBuild())
        profileBuilder.modules.append(try OpenVPNModule.Builder(configurationBuilder: ovpnBuilder).tryBuild())
        profileBuilder.modules.append(try WireGuardModule.Builder(configurationBuilder: wgBuilder).tryBuild())
        let profile = try profileBuilder.tryBuild()

        let coder = CodableProfileCoder()

        let encoded = try sut.encodedProfile(profile, with: coder)
        print(encoded)

        let decoded = try sut.decodedProfile(from: encoded, with: coder)
        XCTAssertEqual(profile, decoded)
    }
#endif
}
