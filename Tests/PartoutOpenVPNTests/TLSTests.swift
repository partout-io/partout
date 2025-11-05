// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@testable import PartoutOpenVPN
import Testing

struct TLSTests {
    let cachesURL = FileManager.default.temporaryDirectory
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
            cachesURL: cachesURL,
            cfg: try newConfiguration(),
            onVerificationFailure: {}
        )
    }
}
