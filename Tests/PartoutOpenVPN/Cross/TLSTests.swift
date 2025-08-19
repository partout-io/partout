// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutOpenVPN
@testable internal import PartoutOpenVPNCross
import Foundation
import Testing

struct TLSTests {
    let cachesURL = FileManager.default.temporaryDirectory

#if canImport(_PartoutOpenVPNLegacy_ObjC)
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
#endif
}

private extension TLSTests {
    func newConfiguration() throws -> OpenVPN.Configuration {
        let url = try #require(Bundle.module.url(forResource: "tunnelbear", withExtension: "ovpn"))
        return try StandardOpenVPNParser(supportsLZO: false, decrypter: SimpleKeyDecrypter())
            .parsed(fromURL: url, passphrase: "foobar")
            .configuration
    }

    func emptyParameters() throws -> TLSWrapper.Parameters {
        TLSWrapper.Parameters(
            cachesURL: cachesURL,
            cfg: try newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
