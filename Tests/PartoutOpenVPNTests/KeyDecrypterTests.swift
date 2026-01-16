// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPNConnection
import Testing

struct KeyDecrypterTests {
    @Test
    func givenDecrypter_whenParsePKCS1_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.1.key")
        #expect(throws: Error.self) {
            _ = try sut.decryptedKey(fromPath: path, passphrase: "")
        }
    }

    @Test
    func givenDecrypter_whenParsePKCS1WithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.1.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        #expect(pem == expected)
    }

    @Test
    func givenDecrypter_whenParsePKCS8_thenFails() throws {
        let sut = newDecrypter()
        let path = try path(withName: "tunnelbear.enc.8.key")
        #expect(throws: Error.self) {
            _ = try sut.decryptedKey(fromPath: path, passphrase: "")
        }
    }

    @Test
    func givenDecrypter_whenParsePKCS8WithPassphrase_thenSucceeds() throws {
        let sut = newDecrypter()
        let expected = try String(contentsOfFile: path(withName: "tunnelbear.key"))
        let path = try path(withName: "tunnelbear.enc.8.key")
        let pem = try sut.decryptedKey(fromPath: path, passphrase: "foobar")
        #expect(pem == expected)
    }
}

private extension KeyDecrypterTests {
    func newDecrypter() -> SimpleKeyDecrypter {
        SimpleKeyDecrypter()
    }

    func path(withName name: String) throws -> String {
        try #require(Bundle.module.path(forResource: name, ofType: nil))
    }
}
