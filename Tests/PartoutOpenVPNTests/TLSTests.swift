// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPNConnection
import Testing

struct TLSTests {
    let cachesURL = FileManager.default.makeTemporaryURL(filename: "")
}

extension TLSTests {
    func newConfiguration() throws -> OpenVPN.Configuration {
        let url = try #require(Bundle.module.url(forResource: "tunnelbear", withExtension: "ovpn"))
        return try StandardOpenVPNParser(decrypter: SimpleKeyDecrypter())
            .parsed(fromURL: url, passphrase: "foobar")
            .configuration
    }

    func emptyParameters() throws -> TLSWrapper.Parameters {
        TLSWrapper.Parameters(
            cachesURL: cachesURL as! URL,
            cfg: try newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
