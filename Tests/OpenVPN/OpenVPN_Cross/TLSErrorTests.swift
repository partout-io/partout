//
//  TLSErrorTests.swift
//  Partout
//
//  Created by Davide De Rosa on 6/28/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import _PartoutOpenVPNCore
@testable internal import _PartoutOpenVPN_Cross
import XCTest

final class TLSErrorTests: XCTestCase {
    let cachesURL = FileManager.default.temporaryDirectory

#if canImport(_PartoutOpenVPNOpenSSL_ObjC)
    func test_givenTLS_whenCAMD5_thenIsExpected() throws {
        let params = emptyParameters()
        let native = try TLSWrapper.native(with: params)
        let legacy = try TLSWrapper.legacy(with: params)
        let nativeMD5 = try native.tls.caMD5()
        let legacyMD5 = try legacy.tls.caMD5()
        print(nativeMD5)
        print(legacyMD5)
        XCTAssertEqual(nativeMD5, legacyMD5)
    }
#endif
}

private extension TLSErrorTests {
    func newConfiguration() -> OpenVPN.Configuration {
        do {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "tunnelbear", withExtension: "ovpn"))
            return try StandardOpenVPNParser(decrypter: OSSLKeyDecrypter())
                .parsed(fromURL: url, passphrase: "foobar")
                .configuration
        } catch {
            fatalError("Unable to find test configuration")
        }
    }

    func emptyParameters() -> TLSWrapper.Parameters {
        TLSWrapper.Parameters(
            cachesURL: cachesURL,
            cfg: newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
