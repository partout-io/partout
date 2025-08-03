// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct ConfigurationTests {
    @Test
    func givenRandomizeHostnames_whenProcessRemotes_thenHostnamesHaveAlphanumericPrefix() throws {
        var builder = OpenVPN.Configuration.Builder()
        let hostname = "my.host.name"
        let ipv4 = "1.2.3.4"
        builder.remotes = [
            try? ExtendedEndpoint(hostname, .init(.udp, 1111)),
            try? ExtendedEndpoint(ipv4, .init(.udp4, 3333))
        ].compactMap { $0 }
        builder.randomizeHostnames = true
        let cfg = try builder.tryBuild(isClient: false)

        try cfg.processedRemotes(prng: MockPRNG())?
            .forEach {
                let comps = $0.address.rawValue.components(separatedBy: ".")
                let first = try #require(comps.first)
                if $0.isHostname {
                    #expect($0.address.rawValue.hasSuffix(hostname))
                    #expect(first.count == 12)
                    #expect(first.allSatisfy("0123456789abcdef".contains))
                } else {
                    #expect($0.address.rawValue == ipv4)
                }
            }
    }
}

private final class MockPRNG: PRNGProtocol {
    func uint32() -> UInt32 {
        1
    }

    func data(length: Int) -> Data {
        Data(Array(repeating: 1, count: length))
    }

    func safeData(length: Int) -> SecureData {
        SecureData(data(length: length))
    }
}
