// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOpenVPN
#endif

struct PIAHardReset {
    private static let obfuscationKeyLength = 3

    private static let magic = "53eo0rk92gxic98p1asgl5auh59r1vp4lmry1e3chzi100qntd"

    private static let encodedFormat = "\(magic)crypto\t%@|%@\tca\t%@"

    private let ctx: PartoutLoggerContext

    private let caMd5Digest: String

    private let cipherName: String

    private let digestName: String

    init(_ ctx: PartoutLoggerContext, caMd5Digest: String, cipher: OpenVPN.Cipher, digest: OpenVPN.Digest) {
        self.ctx = ctx
        self.caMd5Digest = caMd5Digest
        cipherName = cipher.rawValue.lowercased()
        digestName = digest.rawValue.lowercased()
    }

    func encodedData(prng: PRNGProtocol) throws -> Data {
        let string = String(format: PIAHardReset.encodedFormat, cipherName, digestName, caMd5Digest)
        guard let plainData = string.data(using: .ascii) else {
            pp_log(ctx, .openvpn, .fault, "Unable to encode string to ASCII")
            throw OpenVPNSessionError.assertion
        }
        let keyBytes = prng.data(length: PIAHardReset.obfuscationKeyLength)

        var encodedData = Data(keyBytes)
        for (i, b) in plainData.enumerated() {
            let keyChar = keyBytes[i % keyBytes.count]
            let xorredB = b ^ keyChar

            encodedData.append(xorredB)
        }
        return encodedData
    }
}
