// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Foundation
import Testing

struct SerializationTests {
    @Test
    func givenCoreEntities_whenRoundTrip_thenValuesAreRestored() throws {
        try assertRoundTrip(Address.ip("203.0.113.5", .v4))
        try assertRoundTrip(Address.ip("2001:db8::5", .v6))
        try assertRoundTrip(Address.hostname("vpn.example.com"))
        try assertRoundTrip(try Subnet("10.10.0.8", 24))
        try assertRoundTrip(try Subnet("2001:db8:1::8", 64))
        try assertRoundTrip(try Endpoint("198.51.100.10", 443))
        try assertRoundTrip(EndpointProtocol(.tcp6, 8443))
        try assertRoundTrip(try ExtendedEndpoint("vpn.example.com", EndpointProtocol(.udp4, 1194)))
        try assertRoundTrip(Route(defaultWithGateway: try requireAddress("10.10.0.1")))
        try assertRoundTrip(Route(try Subnet("172.16.0.0", 12), try requireAddress("10.10.0.1")))
        try assertRoundTrip(makeIPv4Settings())
        try assertRoundTrip(makeIPv6Settings())
        try assertRoundTrip(ProfileBehavior(disconnectsOnSleep: true, includesAllNetworks: true))
        try assertRoundTrip(SecureData(Data([0xde, 0xad, 0xbe, 0xef])))
        try assertRoundTrip(DataCount(12_345, 67_890))
        try assertRoundTrip([ConnectionStatus.disconnected, .connecting, .connected, .disconnecting])
        try assertRoundTrip([TunnelStatus.inactive, .activating, .active, .deactivating])
        try assertRoundTrip(
            TunnelSnapshot.Environment(
                connectionStatus: .connected,
                dataCount: DataCount(1_024, 2_048),
                lastErrorCode: "test.error"
            )
        )
        try assertRoundTrip(
            TunnelSnapshot(
                id: IDs.profile,
                isEnabled: true,
                status: .active,
                onDemand: true,
                environment: TunnelSnapshot.Environment(
                    connectionStatus: .connecting,
                    dataCount: DataCount(3, 4),
                    lastErrorCode: "last.error"
                )
            )
        )
        try assertRoundTrip([ModuleType.Custom, .DNS, .HTTPProxy, .IP, .OnDemand, .OpenVPN, .Provider, .WireGuard, .Undefined])

        let legacyModuleType = try JSONDecoder.shared().decode(ModuleType.self, from: Data(#"{"name":"WireGuard"}"#.utf8))
        #expect(legacyModuleType == .WireGuard)

        let options = TunnelControllerOptions(
            dnsFallbackServers: ["1.1.1.1", "2606:4700:4700::1111"],
            logsSnapshots: true,
            minDataCountDelta: 4_096
        )
        let decodedOptions = try decodeEncoded(options, as: TunnelControllerOptions.self)
        #expect(decodedOptions.dnsFallbackServers == options.dnsFallbackServers)
        #expect(decodedOptions.logsSnapshots == options.logsSnapshots)
        #expect(decodedOptions.minDataCountDelta == options.minDataCountDelta)
    }

    @Test
    func givenTaggedModules_whenRoundTrip_thenEveryCaseAndPayloadIsRestored() throws {
        let modules = try makeTaggedModules()
        let data = try encoder().encode(modules)
        let decoded = try JSONDecoder.shared().decode([TaggedModule].self, from: data)

        #expect(decoded == modules)
        #expect(decoded.map(\.containedModule.moduleType) == [
            .Custom,
            .DNS,
            .HTTPProxy,
            .IP,
            .OnDemand,
            .OpenVPN,
            .WireGuard
        ])

        let json = try jsonArray(from: data)
        #expect(json.compactMap { $0["type"] as? String } == [
            "Custom",
            "DNS",
            "HTTPProxy",
            "IP",
            "OnDemand",
            "OpenVPN",
            "WireGuard"
        ])

        let customValue = try requireObject(json[0]["value"])
        #expect(customValue["innerType"] as? String == "Provider")
        let customJSON = try requireObject(customValue["json"])
        #expect(customJSON["label"] as? String == "external-provider")

        let dnsValue = try requireObject(json[1]["value"])
        let dnsProtocol = try requireObject(dnsValue["protocolType"])
        #expect(dnsProtocol["type"] as? String == "https")
        #expect(dnsProtocol["url"] as? String == "https://dns.example.com/query")

        let openVPNValue = try requireObject(json[5]["value"])
        let openVPNConfiguration = try requireObject(openVPNValue["configuration"])
        #expect(openVPNConfiguration["cipher"] as? String == "AES-256-CBC")
        #expect(openVPNConfiguration["authUserPass"] as? Bool == true)
        #expect(openVPNConfiguration["staticChallenge"] as? Bool == true)
        let openVPNCredentials = try requireObject(openVPNValue["credentials"])
        #expect(openVPNCredentials["username"] as? String == "ovpn-user")
        #expect(openVPNCredentials["otpMethod"] as? String == "encode")

        let wireGuardValue = try requireObject(json[6]["value"])
        let wireGuardConfiguration = try requireObject(wireGuardValue["configuration"])
        let wireGuardInterface = try requireObject(wireGuardConfiguration["interface"])
        #expect(wireGuardInterface["privateKey"] as? String == Keys.privateKey)
        #expect((wireGuardConfiguration["peers"] as? [[String: Any]])?.count == 2)
    }

    @Test
    func givenTaggedModuleWithUnknownDiscriminator_whenDecode_thenFails() {
        let data = Data(#"{"type":"Bogus","value":{}}"#.utf8)
        #expect(throws: Error.self) {
            try JSONDecoder.shared().decode(TaggedModule.self, from: data)
        }
    }

    @Test
    func givenProfile_whenConvertToTaggedProfile_thenKnownModulesAndFieldsArePreserved() throws {
        let profile = try makeProfile()
        let tagged = profile.asTaggedProfile

        #expect(tagged.version == 7)
        #expect(tagged.id == IDs.profile)
        #expect(tagged.name == "Serialization Fixture")
        #expect(tagged.modules.map(\.containedModule.moduleType) == [
            .DNS,
            .HTTPProxy,
            .IP,
            .OnDemand,
            .OpenVPN,
            .WireGuard
        ])
        #expect(tagged.activeModulesIds == [
            IDs.dns,
            IDs.httpProxy,
            IDs.ip,
            IDs.onDemand,
            IDs.openVPN
        ])
        #expect(tagged.behavior == ProfileBehavior(disconnectsOnSleep: true, includesAllNetworks: true))
        #expect(tagged.userInfo == [
            "owner": "PartoutCoreTests",
            "priority": 42,
            "flags": ["serialization", "profile", "modules"],
            "metadata": [
                "nested": true,
                "notes": "keeps JSON userInfo stable"
            ]
        ])

        let restored = try tagged.asProfile()
        let expectedDNS = try makeDNSModule()
        let expectedOpenVPN = try makeOpenVPNModule()
        let expectedWireGuard = try makeWireGuardModule()
        #expect(restored == profile)
        #expect(restored.modules.compactMap { $0 as? DNSModule }.first == expectedDNS)
        #expect(restored.modules.compactMap { $0 as? OpenVPNModule }.first == expectedOpenVPN)
        #expect(restored.modules.compactMap { $0 as? WireGuardModule }.first == expectedWireGuard)
    }

    @Test
    func givenTaggedProfile_whenRoundTrip_thenProfileAndJSONShapeAreRestored() throws {
        let profile = try makeProfile()
        let tagged = profile.asTaggedProfile
        let data = try encoder().encode(tagged)
        let decoded = try JSONDecoder.shared().decode(TaggedProfile.self, from: data)

        #expect(decoded == tagged)
        #expect(try decoded.asProfile() == profile)

        let json = try jsonObject(from: data)
        #expect(json["version"] as? Int == 7)
        #expect(json["id"] as? String == IDs.profile.uuidString)
        #expect(json["name"] as? String == "Serialization Fixture")
        #expect((json["modules"] as? [[String: Any]])?.compactMap { $0["type"] as? String } == [
            "DNS",
            "HTTPProxy",
            "IP",
            "OnDemand",
            "OpenVPN",
            "WireGuard"
        ])
        #expect(Set((json["activeModulesIds"] as? [String]) ?? []) == [
            IDs.dns.uuidString,
            IDs.httpProxy.uuidString,
            IDs.ip.uuidString,
            IDs.onDemand.uuidString,
            IDs.openVPN.uuidString
        ])
        let behavior = try requireObject(json["behavior"])
        #expect(behavior["disconnectsOnSleep"] as? Bool == true)
        #expect(behavior["includesAllNetworks"] as? Bool == true)
        let userInfo = try requireObject(json["userInfo"])
        #expect(userInfo["owner"] as? String == "PartoutCoreTests")
        #expect(userInfo["priority"] as? Int == 42)
    }

    @Test
    func givenProfileWithExternalModule_whenConvertToTaggedProfile_thenCustomHandlerRestoresOriginalModule() throws {
        let external = try makeExternalModule()
        let profile = try Profile.Builder(
            version: 7,
            id: IDs.profile,
            name: "External Module",
            modules: [external],
            activeModulesIds: [external.id],
            behavior: nil,
            userInfo: nil
        ).build()

        let tagged = profile.asTaggedProfile
        let custom = try #require(tagged.modules.first)
        #expect(custom.containedModule.moduleType == .Custom)

        let restoredWithoutHandler = try tagged.asProfile()
        #expect(restoredWithoutHandler.modules.first is CustomModule)

        let restoredWithHandler = try tagged.asProfile { module in
            #expect(module.innerType == .Provider)
            let data = try JSONEncoder.shared().encode(module.json)
            return try JSONDecoder.shared().decode(ExternalProviderModule.self, from: data)
        }

        let restoredExternal = try #require(restoredWithHandler.modules.first as? ExternalProviderModule)
        #expect(restoredExternal == external)
        #expect(restoredWithHandler.activeModulesIds == [external.id])
    }

    @Test
    func givenTaggedProfile_whenEncodeRedactingSensitiveData_thenSecretsAreNotSerialized() throws {
        let profile = try makeProfile()
        let encoder = encoder(redactingSensitiveData: true)
        let data = try encoder.encode(profile.asTaggedProfile)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(PartoutLogger.redactedValue))
        #expect(!json.contains("ovpn-user"))
        #expect(!json.contains("ovpn-password"))
        #expect(!json.contains("654321"))
        #expect(!json.contains("PRIVATE KEY"))
        #expect(!json.contains(Keys.privateKey))
        #expect(!json.contains("10.8.0.2"))
    }

    @Test
    func givenTunnelRemoteInfo_whenEncodeAsJSON_thenWrapperPreservesProfileOptionsAndModules() throws {
        let profile = try makeProfile()
        var options = TunnelControllerOptions(
            dnsFallbackServers: ["8.8.8.8", "2001:4860:4860::8888"],
            logsSnapshots: true,
            minDataCountDelta: 512
        )
        let info = TunnelRemoteInfo(
            originalModuleId: IDs.openVPN,
            address: try requireAddress("198.51.100.44"),
            modules: [
                try DNSModule.Builder(
                    id: IDs.remoteDNS,
                    protocolType: .tls,
                    servers: ["9.9.9.9"],
                    dotHostname: "dns.remote.example.com",
                    routesThroughVPN: true
                ).build(),
                IPModule.Builder(
                    id: IDs.remoteIP,
                    ipv4: try IPSettings(subnet: Subnet("10.99.0.2", 24)),
                    mtu: 1_320
                ).build()
            ],
            requiresVirtualDevice: true
        )

        let json = try jsonObject(from: Data(try info.encodedAsJSON(profile, options: options).utf8))
        #expect(json["originalModuleId"] as? String == IDs.openVPN.uuidString)
        #expect(json["address"] as? String == "198.51.100.44")
        #expect(json["requiresVirtualDevice"] as? Bool == true)

        let optionsJSON = try requireObject(json["options"])
        #expect(optionsJSON["dnsFallbackServers"] as? [String] == options.dnsFallbackServers)
        #expect(optionsJSON["logsSnapshots"] as? Bool == true)
        #expect(optionsJSON["minDataCountDelta"] as? Int == 512)

        let profileJSON = try requireObject(json["profile"])
        #expect(profileJSON["id"] as? String == IDs.profile.uuidString)
        let remoteModules = try #require(json["modules"] as? [[String: Any]])
        #expect(remoteModules.compactMap { $0["type"] as? String } == ["DNS", "IP"])
    }
}

private extension SerializationTests {
    func makeTaggedModules() throws -> [TaggedModule] {
        [
            .Custom(try CustomModule(makeExternalModule())),
            .DNS(try makeDNSModule()),
            .HTTPProxy(try makeHTTPProxyModule()),
            .IP(try makeIPModule()),
            .OnDemand(makeOnDemandModule()),
            .OpenVPN(try makeOpenVPNModule()),
            .WireGuard(try makeWireGuardModule())
        ]
    }

    func makeProfile() throws -> Profile {
        try Profile.Builder(
            version: 7,
            id: IDs.profile,
            name: "Serialization Fixture",
            modules: makeProfileTaggedModules().map(\.containedModule),
            activeModulesIds: [
                IDs.dns,
                IDs.httpProxy,
                IDs.ip,
                IDs.onDemand,
                IDs.openVPN
            ],
            behavior: ProfileBehavior(disconnectsOnSleep: true, includesAllNetworks: true),
            userInfo: [
                "owner": "PartoutCoreTests",
                "priority": 42,
                "flags": ["serialization", "profile", "modules"],
                "metadata": [
                    "nested": true,
                    "notes": "keeps JSON userInfo stable"
                ]
            ]
        ).build()
    }

    func makeProfileTaggedModules() throws -> [TaggedModule] {
        [
            .DNS(try makeDNSModule()),
            .HTTPProxy(try makeHTTPProxyModule()),
            .IP(try makeIPModule()),
            .OnDemand(makeOnDemandModule()),
            .OpenVPN(try makeOpenVPNModule()),
            .WireGuard(try makeWireGuardModule())
        ]
    }

    func makeExternalModule() throws -> ExternalProviderModule {
        ExternalProviderModule(
            id: IDs.external,
            label: "external-provider",
            endpoint: try Endpoint("203.0.113.200", 9_443),
            subnet: try Subnet("100.64.0.0", 10),
            metadata: [
                "supportsIPv6": true,
                "weight": 3
            ]
        )
    }

    func makeDNSModule() throws -> DNSModule {
        try DNSModule.Builder(
            id: IDs.dns,
            protocolType: .https,
            servers: ["1.1.1.1", "2606:4700:4700::1111"],
            dohURL: "https://dns.example.com/query",
            domains: ["primary.example.com", "search.example.com"],
            inheritsVPN: false,
            domainPolicy: .matchAndSearch,
            isFirstDomainPrimary: true,
            routesThroughVPN: true
        ).build()
    }

    func makeHTTPProxyModule() throws -> HTTPProxyModule {
        try HTTPProxyModule.Builder(
            id: IDs.httpProxy,
            address: "10.0.0.20",
            port: 3_128,
            secureAddress: "10.0.0.21",
            securePort: 3_129,
            pacURLString: "https://proxy.example.com/proxy.pac",
            bypassDomains: ["internal.example.com", "localhost"]
        ).build()
    }

    func makeIPModule() throws -> IPModule {
        IPModule.Builder(
            id: IDs.ip,
            ipv4: try makeIPv4Settings(),
            ipv6: try makeIPv6Settings(),
            mtu: 1_380
        ).build()
    }

    func makeOnDemandModule() -> OnDemandModule {
        var builder = OnDemandModule.Builder(id: IDs.onDemand)
        builder.policy = .including
        builder.withSSIDs = [
            "Office WiFi": true,
            "Guest WiFi": false
        ]
        builder.withOtherNetworks = [.mobile, .ethernet]
        return builder.build()
    }

    func makeOpenVPNModule() throws -> OpenVPNModule {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = .aes256cbc
        builder.dataCiphers = [.aes256gcm, .aes128gcm, .aes128cbc]
        builder.digest = .sha256
        builder.compressionFraming = .compressV2
        builder.compressionAlgorithm = .LZO
        builder.ca = OpenVPN.CryptoContainer(pem: pem(named: "CERTIFICATE", body: "ca-body"))
        builder.clientCertificate = OpenVPN.CryptoContainer(pem: pem(named: "CERTIFICATE", body: "client-cert-body"))
        builder.clientKey = OpenVPN.CryptoContainer(pem: pem(named: "PRIVATE KEY", body: "client-key-body"))
        builder.tlsWrap = OpenVPN.TLSWrap(
            strategy: .cryptV2,
            key: OpenVPN.StaticKey(data: Data((0..<256).map { UInt8($0) }), direction: .client),
            wrappedKey: SecureData(Data([0x10, 0x20, 0x30, 0x40]))
        )
        builder.tlsSecurityLevel = 2
        builder.keepAliveInterval = 10
        builder.keepAliveTimeout = 60
        builder.renegotiatesAfter = 3_600
        builder.remotes = [
            try ExtendedEndpoint("vpn.example.com", EndpointProtocol(.udp4, 1_194)),
            try ExtendedEndpoint("2001:db8::1194", EndpointProtocol(.tcp6, 443))
        ]
        builder.checksEKU = true
        builder.checksSANHost = true
        builder.sanHost = "vpn.example.com"
        builder.randomizeEndpoint = true
        builder.randomizeHostnames = false
        builder.usesPIAPatches = true
        builder.mtu = 1_420
        builder.authUserPass = true
        builder.authToken = "auth-token"
        builder.peerId = 77
        builder.ipv4 = try makeIPv4Settings()
        builder.ipv6 = try makeIPv6Settings()
        builder.routes4 = [
            Route(try Subnet("10.200.0.0", 16), try requireAddress("10.8.0.1")),
            Route(defaultWithGateway: try requireAddress("10.8.0.1"))
        ]
        builder.routes6 = [
            Route(try Subnet("2001:db8:200::", 48), try requireAddress("2001:db8::1")),
            Route(defaultWithGateway: try requireAddress("2001:db8::1"))
        ]
        builder.routeGateway4 = try requireAddress("10.8.0.1")
        builder.routeGateway6 = try requireAddress("2001:db8::1")
        builder.dnsServers = ["10.0.0.53", "2001:4860:4860::8888"]
        builder.dnsDomain = "vpn.example.com"
        builder.searchDomains = ["corp.example.com", "svc.example.com"]
        builder.httpProxy = try Endpoint("10.0.0.10", 8_080)
        builder.httpsProxy = try Endpoint("10.0.0.11", 8_443)
        builder.proxyAutoConfigurationURL = URL(string: "https://proxy.example.com/proxy.pac")
        builder.proxyBypassDomains = ["internal.example.com", "localhost"]
        builder.routingPolicies = [.IPv4, .IPv6, .blockLocal]
        builder.noPullMask = [.dns, .proxy]
        builder.xorMethod = .obfuscate(mask: SecureData(Data([0x13, 0x37, 0x42])))

        let credentials = OpenVPN.Credentials.Builder(
            username: "ovpn-user",
            password: "ovpn-password",
            otpMethod: .encode,
            otp: "654321"
        ).build()
        return try OpenVPNModule.Builder(
            id: IDs.openVPN,
            configurationBuilder: builder,
            credentials: credentials,
            isInteractive: true
        ).build()
    }

    func makeWireGuardModule() throws -> WireGuardModule {
        var interface = WireGuard.LocalInterface.Builder(privateKey: Keys.privateKey)
        interface.addresses = ["10.14.0.2/32", "fd00:14::2/128"]
        interface.dns = DNSModule.Builder(
            id: IDs.wireGuardDNS,
            protocolType: .tls,
            servers: ["9.9.9.9", "2620:fe::fe"],
            dotHostname: "dns.wg.example.com",
            domains: ["wg.example.com", "search.wg.example.com"],
            inheritsVPN: false,
            domainPolicy: .match,
            isFirstDomainPrimary: true,
            routesThroughVPN: true
        )
        interface.mtu = 1_280

        var firstPeer = WireGuard.RemoteInterface.Builder(publicKey: Keys.publicKey)
        firstPeer.preSharedKey = Keys.preSharedKey
        firstPeer.endpoint = "wg.example.com:51820"
        firstPeer.allowedIPs = ["0.0.0.0/0", "::/0", "10.20.0.0/16"]
        firstPeer.keepAlive = 25

        var secondPeer = WireGuard.RemoteInterface.Builder(publicKey: Keys.backupPublicKey)
        secondPeer.endpoint = "2001:db8::20:51821"
        secondPeer.allowedIPs = ["192.0.2.0/24", "2001:db8:abcd::/48"]

        let configurationBuilder = WireGuard.Configuration.Builder(
            interface: interface,
            peers: [firstPeer, secondPeer]
        )
        return try WireGuardModule.Builder(
            id: IDs.wireGuard,
            configurationBuilder: configurationBuilder
        ).build()
    }

    func makeIPv4Settings() throws -> IPSettings {
        IPSettings(subnets: [
            try Subnet("10.8.0.2", 24),
            try Subnet("10.9.0.2", 24)
        ])
        .including(routes: [
            Route(try Subnet("172.16.0.0", 12), try requireAddress("10.8.0.1")),
            Route(defaultWithGateway: try requireAddress("10.8.0.1"))
        ])
        .excluding(routes: [
            Route(try Subnet("192.168.0.0", 16), nil)
        ])
    }

    func makeIPv6Settings() throws -> IPSettings {
        IPSettings(subnets: [
            try Subnet("2001:db8:1::2", 64),
            try Subnet("2001:db8:2::2", 64)
        ])
        .including(routes: [
            Route(try Subnet("2001:db8:100::", 48), try requireAddress("2001:db8::1")),
            Route(defaultWithGateway: try requireAddress("2001:db8::1"))
        ])
        .excluding(routes: [
            Route(try Subnet("fd00:dead:beef::", 48), nil)
        ])
    }

    func pem(named name: String, body: String) -> String {
        """
        -----BEGIN \(name)-----
        \(body)
        -----END \(name)-----
        """
    }
}

private struct ExternalProviderModule: Module, Hashable, Codable {
    static let moduleType: ModuleType = .Provider

    let id: UniqueID

    let label: String

    let endpoint: Endpoint

    let subnet: Subnet

    let metadata: JSON

    var isMutuallyExclusive: Bool {
        false
    }
}

private func assertRoundTrip<T>(_ value: T) throws where T: Codable & Equatable {
    let decoded = try decodeEncoded(value, as: T.self)
    #expect(decoded == value)
}

private func decodeEncoded<T, U>(_ value: T, as type: U.Type) throws -> U where T: Encodable, U: Decodable {
    let data = try encoder().encode(value)
    return try JSONDecoder.shared().decode(type, from: data)
}

private func encoder(redactingSensitiveData: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder.shared()
    encoder.outputFormatting = [.sortedKeys]
    if redactingSensitiveData {
        encoder.userInfo = [.redactingSensitiveData: true]
    }
    return encoder
}

private func requireAddress(_ rawValue: String) throws -> Address {
    try #require(Address(rawValue: rawValue))
}

private func jsonArray(from data: Data) throws -> [[String: Any]] {
    try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requireObject(_ value: Any?) throws -> [String: Any] {
    try #require(value as? [String: Any])
}

private enum IDs {
    static let profile = UniqueID(uuidString: "00000000-0000-0000-0000-000000000100")!
    static let external = UniqueID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let dns = UniqueID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let httpProxy = UniqueID(uuidString: "00000000-0000-0000-0000-000000000103")!
    static let ip = UniqueID(uuidString: "00000000-0000-0000-0000-000000000104")!
    static let onDemand = UniqueID(uuidString: "00000000-0000-0000-0000-000000000105")!
    static let openVPN = UniqueID(uuidString: "00000000-0000-0000-0000-000000000106")!
    static let wireGuard = UniqueID(uuidString: "00000000-0000-0000-0000-000000000107")!
    static let wireGuardDNS = UniqueID(uuidString: "00000000-0000-0000-0000-000000000108")!
    static let remoteDNS = UniqueID(uuidString: "00000000-0000-0000-0000-000000000109")!
    static let remoteIP = UniqueID(uuidString: "00000000-0000-0000-0000-000000000110")!
}

private enum Keys {
    static let privateKey = Data(repeating: 0x01, count: 32).base64EncodedString()
    static let publicKey = Data(repeating: 0x02, count: 32).base64EncodedString()
    static let preSharedKey = Data(repeating: 0x03, count: 32).base64EncodedString()
    static let backupPublicKey = Data(repeating: 0x04, count: 32).base64EncodedString()
}
