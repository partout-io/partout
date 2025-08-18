// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import Foundation
#if !PARTOUT_MONOLITH
internal import _PartoutVendorsPortable
import PartoutOpenVPN
#endif

extension CryptoKeys {
    struct PRF {
        let handshake: Handshake

        let sessionId: Data

        let remoteSessionId: Data
    }

    init(withPRF prf: PRF) throws {
        let masterData = try Self.prfData(with: PRFInput(
            label: Constants.Keys.label1,
            secret: CZ(prf.handshake.preMaster),
            clientSeed: CZ(prf.handshake.random1),
            serverSeed: CZ(prf.handshake.serverRandom1),
            clientSessionId: nil,
            serverSessionId: nil,
            size: Constants.Keys.preMasterLength
        ))
        let keysData = try Self.prfData(with: PRFInput(
            label: Constants.Keys.label2,
            secret: masterData,
            clientSeed: CZ(prf.handshake.random2),
            serverSeed: CZ(prf.handshake.serverRandom2),
            clientSessionId: prf.sessionId,
            serverSessionId: prf.remoteSessionId,
            size: Constants.Keys.keysCount * Constants.Keys.keyLength
        ))
        assert(keysData.count == Constants.Keys.keysCount * Constants.Keys.keyLength)

        let keysArray = (0..<Constants.Keys.keysCount).map {
            let offset = $0 * Constants.Keys.keyLength
            return keysData.withOffset(offset, length: Constants.Keys.keyLength)
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
        let len = input.secret.count / 2
        let lenx = len + (input.secret.count & 1)
        let secret1 = input.secret.withOffset(0, length: lenx)
        let secret2 = input.secret.withOffset(len, length: lenx)

        let hash1 = try keysHash("MD5", secret1, seed, input.size)
        let hash2 = try keysHash("SHA1", secret2, seed, input.size)

        let prf = CZ()
        for i in 0..<hash1.count {
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
        while out.count < size {
            out.append(try buffer.hmac(with: digestName, secret: secret, data: chain.appending(seed)))
            chain = try buffer.hmac(with: digestName, secret: secret, data: chain)
        }
        return out.withOffset(0, length: size)
    }
}
