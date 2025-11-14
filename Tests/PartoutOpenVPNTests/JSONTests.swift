// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct JSONTests {
    @Test
    func givenProtonVPN_whenConvertToJSON_thenFieldsExist() throws {
        let pair = try subjectPair(withSensitiveData: false)
        let sut = pair.json

        #expect(sut["remotes"] != nil)
        #expect(sut["randomizeEndpoint"] != nil)
        #expect(sut["authUserPass"] != nil)
        #expect(sut["renegotiatesAfter"] != nil)
        #expect(sut["cipher"] != nil)
        #expect(sut["digest"] != nil)
        #expect(sut["ca"] != nil)
        #expect(sut["tlsWrap"] != nil)
        #expect(sut["xorMethod"] != nil)
        #expect(sut["mtu"] != nil)
        #expect(sut["checksEKU"] != nil)
        #expect(sut["dnsServers"] == nil)
        #expect(sut["clientCertificate"] == nil)
        #expect(sut["clientKey"] == nil)
    }

    @Test
    func givenProtonVPN_whenConvertToJSON_thenFieldsAreDisclosed() throws {
        let pair = try subjectPair(withSensitiveData: true)
        let sut = pair.json
        let cfg = pair.cfg

        #expect(sut["ca"] as? String == cfg.ca?.pem)

        let tlsWrap = try #require(sut["tlsWrap"] as? [String: Any])
        let tlsWrapKey = try #require(tlsWrap["key"] as? [String: Any])
        #expect(tlsWrapKey["data"] as? String == cfg.tlsWrap?.key.secureData.toData().base64EncodedString())

        let xorMethod = try #require(sut["xorMethod"] as? [String: Any])
        let xorMethodObfuscate = try #require(xorMethod["obfuscate"] as? [String: Any])
        #expect(xorMethodObfuscate["mask"] as? String == cfg.xorMethod?.mask?.toData().base64EncodedString())

        let remotes = try #require(sut["remotes"] as? [String])
        let rawRemotes = Set(remotes)
        let cfgRemotes = Set(cfg.remotes?.map(\.description) ?? [])
        #expect(rawRemotes == cfgRemotes)
    }

    @Test
    func givenProtonVPN_whenConvertToSensitiveJSON_thenFieldsAreRedacted() throws {
        let pair = try subjectPair(withSensitiveData: false)
        let sut = pair.json

        #expect(sut["ca"] as? String == JSONEncoder.redactedValue)

        let tlsWrap = try #require(sut["tlsWrap"] as? [String: Any])
        let tlsWrapKey = try #require(tlsWrap["key"] as? [String: Any])
        #expect(tlsWrapKey["data"] as? String == JSONEncoder.redactedValue)

        let xorMethod = try #require(sut["xorMethod"] as? [String: Any])
        let xorMethodObfuscate = try #require(xorMethod["obfuscate"] as? [String: Any])
        #expect(xorMethodObfuscate["mask"] as? String == JSONEncoder.redactedValue)

        let remotes = try #require(sut["remotes"] as? [String])
        remotes.forEach {
            #expect($0.contains(JSONEncoder.redactedValue))
        }
    }
}

// MARK: - Helpers

private extension JSONTests {
    func subjectPair(withSensitiveData: Bool) throws -> (cfg: OpenVPN.Configuration, json: [String: Any]) {
        let parser = StandardOpenVPNParser(decrypter: nil)
        let url = try #require(Bundle.module.url(forResource: "protonvpn", withExtension: "ovpn"))
        let result = try parser.parsed(fromURL: url)
        let cfg = result.configuration

        let jsonString = try #require(cfg.asJSON(.global, withSensitiveData: withSensitiveData))
        print(jsonString)
        let jsonData = try #require(jsonString.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        return (cfg, json)
    }
}
