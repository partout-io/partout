// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPN
import Testing

private let backend: CryptoBackend = .default

struct TLSTests {
    let cachesURL = FileManager.default.makeTemporaryURL(filename: "")
}

extension TLSTests {
    func newConfiguration() throws -> OpenVPN.Configuration {
        let url = try #require(Bundle.module.url(forResource: "tunnelbear", withExtension: "ovpn"))
        return try StandardOpenVPNParser(decrypter: SimpleKeyDecrypter(backend: .default))
            .parsed(fromURL: url, passphrase: "foobar")
            .configuration
    }

    func emptyParameters() throws -> TLSWrapper.Parameters {
        TLSWrapper.Parameters(
            fnt: backend.functionTable.tls,
            cachesURL: cachesURL,
            cfg: try newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
