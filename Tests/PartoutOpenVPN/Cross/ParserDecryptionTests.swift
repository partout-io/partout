// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutOpenVPN
@testable internal import PartoutOpenVPNCross
import Testing

struct ParserDecryptionTests {
    func givenPKCS1_whenParse_thenFails() {
        let sut = newParser()
        let cfgURL = url(withName: "tunnelbear.enc.1")
        #expect(throws: StandardOpenVPNParserError.self) {
            try sut.parsed(fromURL: cfgURL)
        }
    }

    func givenPKCS1_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newParser()
        let cfgURL = url(withName: "tunnelbear.enc.1")
        _ = try sut.parsed(fromURL: cfgURL, passphrase: "foobar")
    }

    func givenPKCS8_whenParse_thenFails() {
        let sut = newParser()
        let cfgURL = url(withName: "tunnelbear.enc.8")
        #expect(throws: StandardOpenVPNParserError.self) {
            try sut.parsed(fromURL: cfgURL)
        }
    }

    func givenPKCS8_whenParseWithPassphrase_thenSucceeds() throws {
        let sut = newParser()
        let cfgURL = url(withName: "tunnelbear.enc.8")
        #expect(throws: StandardOpenVPNParserError.self) {
            try sut.parsed(fromURL: cfgURL)
        }
        _ = try sut.parsed(fromURL: cfgURL, passphrase: "foobar")
    }
}

private extension ParserDecryptionTests {
    func newParser() -> StandardOpenVPNParser {
        StandardOpenVPNParser(supportsLZO: false, decrypter: SimpleKeyDecrypter())
    }

    func url(withName name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "ovpn")!
    }
}
