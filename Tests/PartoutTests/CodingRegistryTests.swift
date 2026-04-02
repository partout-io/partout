// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import Partout
import Testing

struct CodingRegistryTests {
    @Test(arguments: [true, false])
    func givenCoder_whenEncodeProfileWithKnownHandlers_thenIsDecoded(legacy: Bool) throws {
        let registry = Registry(withKnown: true)
        let sut = registry.withLegacyEncoding(legacy)

        var ovpnBuilder = OpenVPN.Configuration.Builder()
        ovpnBuilder.ca = OpenVPN.CryptoContainer(pem: "ca is required")
        ovpnBuilder.cipher = .aes128cbc
        ovpnBuilder.remotes = [
            try ExtendedEndpoint("host.name", EndpointProtocol(.tcp, 80))
        ]

        var wgBuilder = WireGuard.Configuration.Builder(privateKey: "")
        wgBuilder.peers = [WireGuard.RemoteInterface.Builder(publicKey: "")]

        var profileBuilder = Profile.Builder()
        profileBuilder.modules.append(try DNSModule.Builder().build())
        profileBuilder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).build())
        profileBuilder.modules.append(OnDemandModule.Builder().build())
        profileBuilder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080).build())
        profileBuilder.modules.append(try OpenVPNModule.Builder(configurationBuilder: ovpnBuilder).build())
        profileBuilder.modules.append(try WireGuardModule.Builder(configurationBuilder: wgBuilder).build())
        let profile = try profileBuilder.build()

        let encoded = try sut.string(fromProfile: profile)
        print(encoded)

        let decoded = try sut.profile(fromString: encoded)
        #expect(profile == decoded)
    }

    @Test(arguments: [true, false])
    func givenCoder_whenEncodeProfileWithRegisteredModule_thenIsDecoded(legacy: Bool) throws {
        let registry = Registry(allHandlers: [
            DNSModule.moduleHandler
        ])
        let sut = registry.withLegacyEncoding(legacy)
        let module = try DNSModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()

        let encoded = try sut.string(fromProfile: profile)
        let decoded = try sut.profile(fromString: encoded)
        #expect(decoded == profile)
    }

    @Test(arguments: [true, false])
    func givenCoder_whenEncodeProfile_thenIsDecoded(legacy: Bool) throws {
        let registry = Registry(allHandlers: [
            DNSModule.moduleHandler
        ])
        let sut = registry.withLegacyEncoding(legacy)
        let module = try DNSModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()

        let encoded = try sut.string(fromProfile: profile)
        let decoded = try sut.profile(fromString: encoded)
        #expect(decoded == profile)
    }

    @Test(arguments: [true, false])
    func givenCoder_whenEncodeProfile_thenDecodesToEqual(legacy: Bool) throws {
        let registry = Registry(allHandlers: [
            DNSModule.moduleHandler,
            IPModule.moduleHandler
        ])
        let sut = registry.withLegacyEncoding(legacy)
        let dnsModule = try DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.1.1.1", "4.4.4.4"],
            dotHostname: "hay.com"
        ).build()
        let ipModule = IPModule.Builder(mtu: 1234).build()
        let profile = try Profile.Builder(
            modules: [dnsModule, ipModule],
            userInfo: ["foo": "bar", "zen": 12]
        ).build()

        let encodedString = try sut.string(fromProfile: profile)
        print(encodedString)
        let decodedProfile = try sut.profile(fromString: encodedString)
        print(decodedProfile)
        #expect(decodedProfile.modules[0] as? DNSModule == dnsModule)
        #expect(decodedProfile.modules[1] as? IPModule == ipModule)
        #expect(decodedProfile == profile)
    }
}
