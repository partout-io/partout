// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutOpenVPN
import Testing

extension TLSTests {
    @Test
    func givenTLS_whenCAMD5_thenIsExpected() throws {
        let params = try emptyParameters()
        let native = try TLSWrapper.native(with: params)
        let legacy = try TLSWrapper.legacy(with: params)
        let nativeMD5 = try native.tls.caMD5()
        let legacyMD5 = try legacy.tls.caMD5()
        print(nativeMD5)
        print(legacyMD5)
        #expect(nativeMD5 == legacyMD5)
    }
}
