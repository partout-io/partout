// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout
import Testing

#if canImport(PartoutOpenVPN)
import PartoutOpenVPN
#endif
#if canImport(PartoutWireGuard)
import PartoutWireGuard
#endif
import PartoutCore

struct RegistryTests {

#if canImport(PartoutOpenVPN) && canImport(PartoutWireGuard)
    @Test
    func givenKnownHandlers_whenSerializeProfile_thenIsDeserialized() throws {
        let sut = Registry()

        var ovpnBuilder = OpenVPN.Configuration.Builder()
        ovpnBuilder.ca = OpenVPN.CryptoContainer(pem: "ca is required")
        ovpnBuilder.cipher = .aes128cbc
        ovpnBuilder.remotes = [
            try ExtendedEndpoint("host.name", EndpointProtocol(.tcp, 80))
        ]

        var wgBuilder = WireGuard.Configuration.Builder(privateKey: "")
        wgBuilder.peers = [WireGuard.RemoteInterface.Builder(publicKey: "")]

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
        #expect(profile == decoded)
    }
#endif
}
