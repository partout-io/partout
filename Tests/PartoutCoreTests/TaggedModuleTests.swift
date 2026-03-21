// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Foundation
import Testing

struct TaggedModuleTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    @Test
    func givenTaggedModules_whenEncode_thenTypeDiscriminatorsAreIncluded() throws {
        let taggedModules = try makeTaggedModules()
        let data = try encoder.encode(taggedModules)
        let json = String(decoding: data, as: UTF8.self)
        print(json)
        #expect(json.contains(#""type" : "DNS""#))
        #expect(json.contains(#""type" : "HTTPProxy""#))
        #expect(json.contains(#""type" : "IP""#))
        #expect(json.contains(#""type" : "OnDemand""#))
    }

    private func makeTaggedModules() throws -> [TaggedModule] {
        let dnsModule = try DNSModule.Builder(id: IDs.dns).build()
        let httpProxyModule = try HTTPProxyModule.Builder(id: IDs.httpProxy).build()
        let ipModule = IPModule.Builder(id: IDs.ip).build()
        let onDemandModule = OnDemandModule.Builder(id: IDs.onDemand).build()
        return [
            .dns(dnsModule),
            .httpProxy(httpProxyModule),
            .ip(ipModule),
            .onDemand(onDemandModule)
        ]
    }
}

private enum IDs {
    static let dns = UniqueID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let httpProxy = UniqueID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let ip = UniqueID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let onDemand = UniqueID(uuidString: "00000000-0000-0000-0000-000000000004")!
}
