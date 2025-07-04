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
import Foundation
import Testing

struct KeyDecrypterTests {
    @Test
    func givenPKCS1_whenParse_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.1.key")
        do {
            _ = try sut.decryptedKey(fromPath: path, passphrase: "")
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test
    func givenPKCS1_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.1.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        #expect(pem == expected)
    }

    @Test
    func givenPKCS8_whenParse_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.8.key")
        do {
            _ = try sut.decryptedKey(fromPath: path, passphrase: "")
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test
    func givenPKCS8_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.8.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        #expect(pem == expected)
    }
}

private extension KeyDecrypterTests {
    func newDecrypter() -> OSSLKeyDecrypter {
        OSSLKeyDecrypter()
    }

    func path(withName name: String) throws -> String {
        guard let file = Bundle.module.path(forResource: name, ofType: nil) else {
            fatalError("Unable to find path for \(name)")
        }
        return file
    }
}
