// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPN
import Testing

struct TLSTests {
    let cachesPath = FileManager.default.makeTemporaryPath(filename: "")
}

extension TLSTests {
    func newConfiguration() throws -> OpenVPN.Configuration {
        let foundationURL = try #require(Bundle.module.url(forResource: "tunnelbear", withExtension: "ovpn"))
        let url = URL(foundationURL)
        return try StandardOpenVPNParser(decrypter: SimpleKeyDecrypter())
            .parsed(fromURL: url, passphrase: "foobar")
            .configuration
    }

    func emptyParameters() throws -> TLSWrapper.Parameters {
        TLSWrapper.Parameters(
            cachesPath: cachesPath,
            cfg: try newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
