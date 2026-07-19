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

    // MARK: - Custom codable

    @Test
    func givenSingleValueCodableEntities_whenEncodeDecode_thenRawStringPayloadsAreStable() throws {
        try assertSingleStringRoundTrip(Address.ip("203.0.113.5", .v4), "203.0.113.5")
        try assertSingleStringRoundTrip(Address.ip("2001:db8::5", .v6), "2001:db8::5")
        try assertSingleStringRoundTrip(Address.hostname("vpn.example.com"), "vpn.example.com")
        try assertSingleStringRoundTrip(try Subnet("10.10.0.8", 24), "10.10.0.8/24")
        try assertSingleStringRoundTrip(try Subnet("2001:db8:1::8", 64), "2001:db8:1::8/64")
        try assertSingleStringRoundTrip(try Endpoint("198.51.100.10", 443), "198.51.100.10:443")
        try assertSingleStringRoundTrip(try Endpoint("2001:db8::10", 443), "2001:db8::10:443")
        try assertSingleStringRoundTrip(EndpointProtocol(.tcp6, 8443), "TCP6:8443")
        try assertSingleStringRoundTrip(try ExtendedEndpoint("vpn.example.com", EndpointProtocol(.udp4, 1194)), "vpn.example.com:UDP4:1194")
        try assertSingleStringRoundTrip(try ExtendedEndpoint("2001:db8::20", EndpointProtocol(.tcp6, 443)), "2001:db8::20:TCP6:443")
        try assertSingleStringRoundTrip(try requireWireGuardKey(Keys.privateKey), Keys.privateKey)
        try assertSingleStringRoundTrip(SecureData(Data([0xde, 0xad, 0xbe, 0xef])), "3q2+7w==")

        let pem = pem(named: "CERTIFICATE", body: "certificate-body")
        let crypto = OpenVPN.CryptoContainer(pem: "ignored preamble\n\(pem)")
        try assertSingleStringRoundTrip(crypto, pem)
        #expect(crypto.pem == pem)

        let moduleId = UniqueID(uuidString: IDs.dns.uuidString)!
        let moduleIdData = try encoder().encode(moduleId)
        #expect(try JSONDecoder.shared().decode(String.self, from: moduleIdData) == IDs.dns.uuidString)
        #expect(try JSONDecoder.shared().decode(UniqueID.self, from: moduleIdData) == IDs.dns)
    }

    @Test
    func givenSingleValueCodableEntities_whenDecodeMalformedPayloads_thenFailOrNormalizeAsExpected() {
        #expect(throws: Error.self) {
            try decodeSingleString(Address.self, from: PartoutLogger.redactedValue)
        }
        #expect(throws: Error.self) {
            try decodeSingleString(Subnet.self, from: "vpn.example.com/24")
        }
        #expect(throws: Error.self) {
            try decodeSingleString(Endpoint.self, from: "198.51.100.10:not-a-port")
        }
        #expect(throws: Error.self) {
            try decodeSingleString(EndpointProtocol.self, from: "SCTP:1194")
        }
        #expect(throws: Error.self) {
            try decodeSingleString(ExtendedEndpoint.self, from: "vpn.example.com:ICMP:0")
        }
        #expect(throws: Error.self) {
            try decodeSingleString(WireGuard.Key.self, from: "not base64")
        }
        #expect(throws: Error.self) {
            try decodeSingleString(SecureData.self, from: PartoutLogger.redactedValue)
        }

        let malformedCrypto = try? decodeSingleString(OpenVPN.CryptoContainer.self, from: "not a pem")
        #expect(malformedCrypto?.pem == "")
    }

    @Test
    func givenSensitiveSingleValueCodableEntities_whenEncodeRedacting_thenRawValuesAreRedacted() throws {
        try assertRedactedString(Address.ip("203.0.113.5", .v4), PartoutLogger.redactedValue)
        try assertRedactedString(try Subnet("10.10.0.8", 24), "\(PartoutLogger.redactedValue)/24")
        try assertRedactedString(try Endpoint("198.51.100.10", 443), "\(PartoutLogger.redactedValue):443")
        try assertRedactedString(try ExtendedEndpoint("vpn.example.com", EndpointProtocol(.udp4, 1194)), "\(PartoutLogger.redactedValue):UDP4:1194")
        try assertRedactedString(try requireWireGuardKey(Keys.privateKey), PartoutLogger.redactedValue)
        try assertRedactedString(SecureData(Data([0xde, 0xad, 0xbe, 0xef])), PartoutLogger.redactedValue)
        try assertRedactedString(OpenVPN.CryptoContainer(pem: pem(named: "PRIVATE KEY", body: "private-key-body")), PartoutLogger.redactedValue)
    }

    @Test
    func givenDNSProtocolType_whenEncodeDecode_thenTaggedLegacySensitiveAndMalformedPathsAreCovered() throws {
        let httpsURL = try #require(URL(string: "https://dns.example.com/query"))
        let values: [DNSModule.ProtocolType] = [
            .cleartext,
            .https(url: httpsURL),
            .tls(hostname: "dns.example.com")
        ]

        for value in values {
            try assertRoundTrip(value)
        }

        let cleartextJSON = try jsonObject(from: encoder().encode(DNSModule.ProtocolType.cleartext))
        #expect(cleartextJSON["type"] as? String == "cleartext")
        #expect(cleartextJSON["url"] == nil)
        #expect(cleartextJSON["hostname"] == nil)

        let httpsJSON = try jsonObject(from: encoder().encode(DNSModule.ProtocolType.https(url: httpsURL)))
        #expect(httpsJSON["type"] as? String == "https")
        #expect(httpsJSON["url"] as? String == "https://dns.example.com/query")

        let tlsJSON = try jsonObject(from: encoder().encode(DNSModule.ProtocolType.tls(hostname: "dns.example.com")))
        #expect(tlsJSON["type"] as? String == "tls")
        #expect(tlsJSON["hostname"] as? String == "dns.example.com")

        let legacyHTTPSJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(DNSModule.ProtocolType.https(url: httpsURL)))
        #expect(try requireObject(legacyHTTPSJSON["https"])["url"] as? String == "https://dns.example.com/query")
        let legacyTLSJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(DNSModule.ProtocolType.tls(hostname: "dns.example.com")))
        #expect(try requireObject(legacyTLSJSON["tls"])["hostname"] as? String == "dns.example.com")

        let redactedHTTPSJSON = try jsonObject(from: encoder(redactingSensitiveData: true).encode(DNSModule.ProtocolType.https(url: httpsURL)))
        #expect(redactedHTTPSJSON["url"] as? String == PartoutLogger.redactedValue)
        let redactedTLSJSON = try jsonObject(from: encoder(redactingSensitiveData: true).encode(DNSModule.ProtocolType.tls(hostname: "dns.example.com")))
        #expect(redactedTLSJSON["hostname"] as? String == PartoutLogger.redactedValue)

        #expect(try decode(DNSModule.ProtocolType.self, from: #"{"cleartext":{}}"#) == .cleartext)
        #expect(try decode(DNSModule.ProtocolType.self, from: #"{"https":{"url":"https://dns.example.com/query"}}"#) == .https(url: httpsURL))
        #expect(try decode(DNSModule.ProtocolType.self, from: #"{"tls":{"hostname":"dns.example.com"}}"#) == .tls(hostname: "dns.example.com"))

        #expect(throws: Error.self) {
            try decode(DNSModule.ProtocolType.self, from: #"{"type":"https","hostname":"dns.example.com"}"#)
        }
        #expect(throws: Error.self) {
            try decode(DNSModule.ProtocolType.self, from: #"{"https":{"hostname":"dns.example.com"}}"#)
        }
        #expect(throws: Error.self) {
            try decode(DNSModule.ProtocolType.self, from: #"{"type":"bogus"}"#)
        }
    }

    @Test
    func givenOpenVPNObfuscationMethod_whenEncodeDecode_thenTaggedLegacySensitiveAndMalformedPathsAreCovered() throws {
        let xormask = OpenVPN.ObfuscationMethod.xormask(mask: SecureData(Data([1, 2, 3])))
        let xorptrpos = OpenVPN.ObfuscationMethod.xorptrpos
        let reverse = OpenVPN.ObfuscationMethod.reverse
        let obfuscate = OpenVPN.ObfuscationMethod.obfuscate(mask: SecureData(Data([4, 5, 6])))

        try assertRoundTrip(xormask)
        try assertRoundTrip(xorptrpos)
        try assertRoundTrip(reverse)
        try assertRoundTrip(obfuscate)

        let taggedXORMaskJSON = try jsonObject(from: encoder().encode(xormask))
        #expect(taggedXORMaskJSON["type"] as? String == "xormask")
        #expect(taggedXORMaskJSON["mask"] as? String == "AQID")
        let taggedXORPtrPosJSON = try jsonObject(from: encoder().encode(xorptrpos))
        #expect(taggedXORPtrPosJSON["type"] as? String == "xorptrpos")
        #expect(taggedXORPtrPosJSON["mask"] == nil)
        let taggedReverseJSON = try jsonObject(from: encoder().encode(reverse))
        #expect(taggedReverseJSON["type"] as? String == "reverse")
        #expect(taggedReverseJSON["mask"] == nil)
        let taggedObfuscateJSON = try jsonObject(from: encoder().encode(obfuscate))
        #expect(taggedObfuscateJSON["type"] as? String == "obfuscate")
        #expect(taggedObfuscateJSON["mask"] as? String == "BAUG")

        let legacyXORMaskJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(xormask))
        #expect(try requireObject(legacyXORMaskJSON["xormask"])["mask"] as? String == "AQID")
        let legacyXORPtrPosJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(xorptrpos))
        #expect((legacyXORPtrPosJSON["xorptrpos"] as? [String: Any])?.isEmpty == true)
        let legacyReverseJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(reverse))
        #expect((legacyReverseJSON["reverse"] as? [String: Any])?.isEmpty == true)
        let legacyObfuscateJSON = try jsonObject(from: encoder(legacySwiftEncoding: true).encode(obfuscate))
        #expect(try requireObject(legacyObfuscateJSON["obfuscate"])["mask"] as? String == "BAUG")

        let redactedXORMaskJSON = try jsonObject(from: encoder(redactingSensitiveData: true).encode(xormask))
        #expect(redactedXORMaskJSON["mask"] as? String == PartoutLogger.redactedValue)

        #expect(try decode(OpenVPN.ObfuscationMethod.self, from: #"{"xormask":{"mask":"AQID"}}"#) == xormask)
        #expect(try decode(OpenVPN.ObfuscationMethod.self, from: #"{"xorptrpos":{}}"#) == xorptrpos)
        #expect(try decode(OpenVPN.ObfuscationMethod.self, from: #"{"reverse":{}}"#) == reverse)
        #expect(try decode(OpenVPN.ObfuscationMethod.self, from: #"{"obfuscate":{"mask":"BAUG"}}"#) == obfuscate)

        #expect(throws: Error.self) {
            try decode(OpenVPN.ObfuscationMethod.self, from: #"{"type":"xormask"}"#)
        }
        #expect(throws: Error.self) {
            try decode(OpenVPN.ObfuscationMethod.self, from: #"{"xormask":{}}"#)
        }
        #expect(throws: Error.self) {
            try decode(OpenVPN.ObfuscationMethod.self, from: #"{"type":"obfuscate"}"#)
        }
        #expect(throws: Error.self) {
            try decode(OpenVPN.ObfuscationMethod.self, from: #"{"obfuscate":{}}"#)
        }
        #expect(throws: Error.self) {
            try decode(OpenVPN.ObfuscationMethod.self, from: #"{"type":"bogus"}"#)
        }
    }

    @Test
    func givenOpenVPNCredentials_whenEncodeDecode_thenSensitiveOptionalAndLegacyOTPPathsAreCovered() throws {
        let credentials = OpenVPN.Credentials.Builder(
            username: "user",
            password: "password",
            otpMethod: .append,
            otp: "123456"
        ).build()
        try assertRoundTrip(credentials)

        let encodedJSON = try jsonObject(from: encoder().encode(credentials))
        #expect(encodedJSON["username"] as? String == "user")
        #expect(encodedJSON["password"] as? String == "password")
        #expect(encodedJSON["otpMethod"] as? String == "append")
        #expect(encodedJSON["otp"] as? String == "123456")

        let redactedJSON = try jsonObject(from: encoder(redactingSensitiveData: true).encode(credentials))
        #expect(redactedJSON["username"] as? String == PartoutLogger.redactedValue)
        #expect(redactedJSON["password"] as? String == PartoutLogger.redactedValue)
        #expect(redactedJSON["otpMethod"] as? String == "append")
        #expect(redactedJSON["otp"] as? String == PartoutLogger.redactedValue)

        let missingOTP = try decode(OpenVPN.Credentials.self, from: #"{"username":"user","password":"password","otpMethod":"none"}"#)
        #expect(missingOTP == OpenVPN.Credentials.Builder(username: "user", password: "password").build())

        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #""none""#) == .none)
        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #""append""#) == .append)
        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #""encode""#) == .encode)
        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #"{"none":{}}"#) == .none)
        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #"{"append":{}}"#) == .append)
        #expect(try decode(OpenVPN.Credentials.OTPMethod.self, from: #"{"encode":{}}"#) == .encode)

        #expect(throws: Error.self) {
            try decode(OpenVPN.Credentials.OTPMethod.self, from: #""bogus""#)
        }
        #expect(throws: Error.self) {
            try decode(OpenVPN.Credentials.OTPMethod.self, from: #"{}"#)
        }
    }

    @Test
    func givenOpenVPNTLSWrap_whenEncodeDecode_thenAllStrategiesAndNestedSecureDataAreCovered() throws {
        let auth = OpenVPN.TLSWrap(
            strategy: .auth,
            key: makeStaticKey(direction: .client)
        )
        let crypt = OpenVPN.TLSWrap(
            strategy: .crypt,
            key: makeStaticKey(direction: nil)
        )
        let cryptV2 = OpenVPN.TLSWrap(
            strategy: .cryptV2,
            key: makeStaticKey(direction: .client),
            wrappedKey: SecureData(Data([0x10, 0x20, 0x30, 0x40]))
        )

        try assertRoundTrip(auth)
        try assertRoundTrip(crypt)
        try assertRoundTrip(cryptV2)

        let authJSON = try jsonObject(from: encoder().encode(auth))
        #expect(authJSON["strategy"] as? String == "auth")
        #expect(try requireObject(authJSON["key"])["dir"] as? Int == 1)
        #expect(authJSON["wrappedKey"] == nil)

        let cryptJSON = try jsonObject(from: encoder().encode(crypt))
        #expect(cryptJSON["strategy"] as? String == "crypt")
        #expect(try requireObject(cryptJSON["key"])["dir"] == nil)
        #expect(cryptJSON["wrappedKey"] == nil)

        let cryptV2JSON = try jsonObject(from: encoder().encode(cryptV2))
        #expect(cryptV2JSON["strategy"] as? String == "crypt-v2")
        #expect(try requireObject(cryptV2JSON["key"])["data"] as? String == makeStaticKeyData().base64EncodedString())
        #expect(cryptV2JSON["wrappedKey"] as? String == "ECAwQA==")

        let redactedCryptV2JSON = try jsonObject(from: encoder(redactingSensitiveData: true).encode(cryptV2))
        #expect(try requireObject(redactedCryptV2JSON["key"])["data"] as? String == PartoutLogger.redactedValue)
        #expect(redactedCryptV2JSON["wrappedKey"] as? String == PartoutLogger.redactedValue)
    }

    @Test
    func givenIPSettingsAndModuleType_whenDecodeCustomPayloads_thenFallbackPathsAreCovered() throws {
        let emptyIPSettings = try decode(IPSettings.self, from: #"{}"#)
        #expect(emptyIPSettings == IPSettings(subnets: [], includedRoutes: [], excludedRoutes: []))

        let partialIPSettings = try decode(IPSettings.self, from: #"{"subnets":["10.10.0.2/24"]}"#)
        #expect(partialIPSettings == IPSettings(
            subnets: [try Subnet("10.10.0.2", 24)],
            includedRoutes: [],
            excludedRoutes: []
        ))

        let moduleTypeData = try encoder().encode(ModuleType.WireGuard)
        #expect(try JSONDecoder.shared().decode(String.self, from: moduleTypeData) == "WireGuard")
        #expect(try JSONDecoder.shared().decode(ModuleType.self, from: moduleTypeData) == .WireGuard)
        #expect(try decode(ModuleType.self, from: #"{"name":"OpenVPN"}"#) == .OpenVPN)
        #expect(try decode(ModuleType.self, from: #""DoesNotExist""#) == .Undefined)
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
    func givenTunnelRemoteInfo_whenEncodeAsJSON_thenWrapperPreservesProfileAndModules() throws {
        let profile = try makeProfile()
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

        let json = try jsonObject(from: Data(try info.encodedAsJSON(profile).utf8))
        #expect(json["originalModuleId"] as? String == IDs.openVPN.uuidString)
        #expect(json["address"] as? String == "198.51.100.44")
        #expect(json["requiresVirtualDevice"] as? Bool == true)

        #expect(json["options"] == nil)

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

private func assertSingleStringRoundTrip<T>(_ value: T, _ rawValue: String) throws where T: Codable & Equatable {
    let data = try encoder().encode(value)
    #expect(try JSONDecoder.shared().decode(String.self, from: data) == rawValue)
    #expect(try JSONDecoder.shared().decode(T.self, from: try encoder().encode(rawValue)) == value)
}

private func assertRedactedString<T>(_ value: T, _ redactedValue: String) throws where T: Encodable {
    let data = try encoder(redactingSensitiveData: true).encode(value)
    #expect(try JSONDecoder.shared().decode(String.self, from: data) == redactedValue)
}

private func decodeEncoded<T, U>(_ value: T, as type: U.Type) throws -> U where T: Encodable, U: Decodable {
    let data = try encoder().encode(value)
    return try JSONDecoder.shared().decode(type, from: data)
}

private func decode<T>(_ type: T.Type, from json: String) throws -> T where T: Decodable {
    try JSONDecoder.shared().decode(T.self, from: Data(json.utf8))
}

private func decodeSingleString<T>(_ type: T.Type, from rawValue: String) throws -> T where T: Decodable {
    try JSONDecoder.shared().decode(T.self, from: try encoder().encode(rawValue))
}

private func encoder(
    legacySwiftEncoding: Bool = false,
    redactingSensitiveData: Bool = false
) -> JSONEncoder {
    let encoder = JSONEncoder.shared()
    encoder.outputFormatting = [.sortedKeys]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    if legacySwiftEncoding {
        userInfo[.legacySwiftEncoding] = true
    }
    if redactingSensitiveData {
        userInfo[.redactingSensitiveData] = true
    }
    encoder.userInfo = userInfo
    return encoder
}

private func requireAddress(_ rawValue: String) throws -> Address {
    try #require(Address(rawValue: rawValue))
}

private func requireWireGuardKey(_ rawValue: String) throws -> WireGuard.Key {
    try #require(WireGuard.Key(rawValue: rawValue))
}

private func makeStaticKeyData() -> Data {
    Data((0..<256).map { UInt8($0) })
}

private func makeStaticKey(direction: OpenVPN.StaticKey.Direction?) -> OpenVPN.StaticKey {
    OpenVPN.StaticKey(data: makeStaticKeyData(), direction: direction)
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
