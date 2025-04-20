//
//  RegistryTests.swift
//  Partout
//
//  Created by Davide De Rosa on 2/24/24.
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
import PartoutSupport
import XCTest

final class RegistryTests: XCTestCase {
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
}
