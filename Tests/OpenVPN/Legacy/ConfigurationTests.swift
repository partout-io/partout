// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutOpenVPN
@testable internal import PartoutOpenVPNLegacy
import PartoutCore
import XCTest

final class ConfigurationTests: XCTestCase {
    func test_givenRandomizeHostnames_whenProcessRemotes_thenHostnamesHaveAlphanumericPrefix() throws {
        var builder = OpenVPN.Configuration.Builder()
        let hostname = "my.host.name"
        let ipv4 = "1.2.3.4"
        builder.remotes = [
            try? ExtendedEndpoint(hostname, .init(.udp, 1111)),
            try? ExtendedEndpoint(ipv4, .init(.udp4, 3333))
        ].compactMap { $0 }
        builder.randomizeHostnames = true
        let cfg = try builder.tryBuild(isClient: false)

        cfg.processedRemotes(prng: MockPRNG())?
            .forEach {
                let comps = $0.address.rawValue.components(separatedBy: ".")
                guard let first = comps.first else {
                    XCTFail()
                    return
                }
                if $0.isHostname {
                    XCTAssert($0.address.rawValue.hasSuffix(hostname))
                    XCTAssertEqual(first.count, 12)
                    XCTAssertTrue(first.allSatisfy("0123456789abcdef".contains))
                } else {
                    XCTAssertEqual($0.address.rawValue, ipv4)
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
