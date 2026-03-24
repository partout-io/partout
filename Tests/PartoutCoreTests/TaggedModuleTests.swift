// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Foundation
import Testing

struct TaggedModuleTests {
    private func encoder(withLegacyEncoding: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.userInfo = [.legacySwiftEncoding: withLegacyEncoding]
        return encoder
    }

    @Test(arguments: [false, true])
    func givenTaggedModules_whenEncode_thenTypeDiscriminatorsAreIncluded(withLegacyEncoding: Bool) throws {
        let taggedModules = try makeTaggedModules()
        let data = try encoder(withLegacyEncoding: withLegacyEncoding)
            .encode(taggedModules)
        let json = String(decoding: data, as: UTF8.self)
        print(json)
        #expect(json.contains(#""type" : "DNS""#))
        #expect(json.contains(#""type" : "HTTPProxy""#))
        #expect(json.contains(#""type" : "IP""#))
        #expect(json.contains(#""type" : "OnDemand""#))
    }

    private func makeTaggedModules() throws -> [TaggedModule] {
        let dnsModule = try DNSModule.Builder(
            id: IDs.dns,
            protocolType: .https,
            dohURL: "https://foobar.com/dns"
        ).build()
        let httpProxyModule = try HTTPProxyModule.Builder(id: IDs.httpProxy).build()
        let ipModule = IPModule.Builder(id: IDs.ip).build()
        let onDemandModule = OnDemandModule.Builder(id: IDs.onDemand).build()
        return [
            .DNS(dnsModule),
            .HTTPProxy(httpProxyModule),
            .IP(ipModule),
            .OnDemand(onDemandModule)
        ]
    }
}

private enum IDs {
    static let dns = UniqueID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let httpProxy = UniqueID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let ip = UniqueID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let onDemand = UniqueID(uuidString: "00000000-0000-0000-0000-000000000004")!
}
