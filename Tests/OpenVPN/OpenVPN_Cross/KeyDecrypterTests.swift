//
//  KeyDecrypterTests.swift
//  Partout
//
//  Created by Davide De Rosa on 6/27/25.
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

@testable internal import _PartoutOpenVPN_Cross
import XCTest

final class KeyDecrypterTests: XCTestCase {
    func test_givenPKCS1_whenParse_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.1.key")
        XCTAssertThrowsError(try sut.decryptedKey(fromPath: path, passphrase: ""))
    }

    func test_givenPKCS1_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.1.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        XCTAssertEqual(pem, expected)
    }

    func test_givenPKCS8_whenParse_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.8.key")
        XCTAssertThrowsError(try sut.decryptedKey(fromPath: path, passphrase: ""))
    }

    func test_givenPKCS8_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.8.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        XCTAssertEqual(pem, expected)
    }
}

private extension KeyDecrypterTests {
    func newDecrypter() -> OSSLKeyDecrypter {
        OSSLKeyDecrypter()
    }

    func path(withName name: String) throws -> String {
        try XCTUnwrap(Bundle.module.path(forResource: name, ofType: nil))
    }
}
