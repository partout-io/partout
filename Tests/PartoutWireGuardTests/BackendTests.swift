// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutWireGuard
import Testing

struct BackendTests {
    @Test
    func givenBackend_whenGetVersion_thenIsExpected() throws {
        let sut = WireGuardBackend()
        let expectedVersion = "f333402"
        let vendorVersion = try #require(sut.version())
        #expect(vendorVersion == expectedVersion)
        print("WireGuard version: \(vendorVersion)")
    }
}
