// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutVendorsWireGuard
import Testing

struct BackendTests {
    @Test
    func givenBackend_whenGetVersion_thenIsExpected() throws {
        let sut = VendorWireGuardBackend()
        let expectedVersion = "f333402"
        let vendorVersion = try #require(sut.version())
        #expect(vendorVersion == expectedVersion)
        print("WireGuard version: \(vendorVersion)")
    }
}
