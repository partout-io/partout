//
//  CryptoKeys+PRF.swift
//  Partout
//
//  Created by Davide De Rosa on 6/20/25.
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

internal import _PartoutCryptoOpenSSL_Cross
import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_C
import Foundation

extension CryptoKeys {
    struct PRF {
        let handshake: Handshake

        let sessionId: Data

        let remoteSessionId: Data
    }

    init(withPRF prf: PRF) throws {
        let masterData = try Self.prfData(with: PRFInput(
            label: Constants.label1,
            secret: CZ(prf.handshake.preMaster),
            clientSeed: CZ(prf.handshake.random1),
            serverSeed: CZ(prf.handshake.serverRandom1),
            clientSessionId: nil,
            serverSessionId: nil,
            size: Constants.preMasterLength
        ))
        let keysData = try Self.prfData(with: PRFInput(
            label: Constants.label2,
            secret: masterData,
            clientSeed: CZ(prf.handshake.random2),
            serverSeed: CZ(prf.handshake.serverRandom2),
            clientSessionId: prf.sessionId,
            serverSessionId: prf.remoteSessionId,
            size: Constants.keysCount * Constants.keyLength
        ))
        assert(keysData.length == Constants.keysCount * Constants.keyLength)

        let keysArray = (0..<Constants.keysCount).map {
            let offset = $0 * Constants.keyLength
            return keysData.withOffset(offset, length: Constants.keyLength)
        }
        self.init(
            cipher: CryptoKeys.KeyPair(
                encryptionKey: keysArray[0],
                decryptionKey: keysArray[2]
            ),
            digest: CryptoKeys.KeyPair(
                encryptionKey: keysArray[1],
                decryptionKey: keysArray[3]
            )
        )
    }
}

// MARK: - Helpers

private struct PRFInput {
    let label: String

    let secret: CZeroingData

    let clientSeed: CZeroingData

    let serverSeed: CZeroingData

    let clientSessionId: Data?

    let serverSessionId: Data?

    let size: Int
}

private extension CryptoKeys {
    static func prfData(with input: PRFInput) throws -> CZeroingData {
        let seed = CZ(input.label, nullTerminated: false)
        seed.append(input.clientSeed)
        seed.append(input.serverSeed)
        if let csi = input.clientSessionId {
            seed.append(CZ(csi))
        }
        if let ssi = input.serverSessionId {
            seed.append(CZ(ssi))
        }
        let len = input.secret.length / 2
        let lenx = len + (input.secret.length & 1)
        let secret1 = input.secret.withOffset(0, length: lenx)
        let secret2 = input.secret.withOffset(len, length: lenx)

        let hash1 = try keysHash("md5", secret1, seed, input.size)
        let hash2 = try keysHash("sha1", secret2, seed, input.size)

        let prf = CZ()
        for i in 0..<hash1.length {
            let h1 = hash1.bytes[i]
            let h2 = hash2.bytes[i]

            prf.append(CZ(h1 ^ h2))
        }
        return prf
    }

    static func keysHash(_ digestName: String, _ secret: CZeroingData, _ seed: CZeroingData, _ size: Int) throws -> CZeroingData {
        let out = CZ()
        let buffer = CZeroingData.forHMAC()
        var chain = try buffer.hmac(with: digestName, secret: secret, data: seed)
        while out.length < size {
            out.append(try buffer.hmac(with: digestName, secret: secret, data: chain.appending(seed)))
            chain = try buffer.hmac(with: digestName, secret: secret, data: chain)
        }
        return out.withOffset(0, length: size)
    }
}
