//
//  DataPathWrapper+Keys.swift
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

import _PartoutOpenVPN
internal import _PartoutOpenVPNOpenSSL_C
import Foundation

extension DataPathWrapper.Parameters {
    struct PRF {
        let authResponse: Authenticator.Response

        let sessionId: Data

        let remoteSessionId: Data
    }

    func keys(with prf: PRF) throws -> CryptoKeys {
        let masterData = try keysPRF(parameters: PRFParameters(
            label: Constants.label1,
            secret: CZ(prf.authResponse.preMaster),
            clientSeed: CZ(prf.authResponse.random1),
            serverSeed: CZ(prf.authResponse.serverRandom1),
            clientSessionId: nil,
            serverSessionId: nil,
            size: Constants.preMasterLength
        ))
        let keysData = try keysPRF(parameters: PRFParameters(
            label: Constants.label2,
            secret: masterData,
            clientSeed: CZ(prf.authResponse.random2),
            serverSeed: CZ(prf.authResponse.serverRandom2),
            clientSessionId: prf.sessionId,
            serverSessionId: prf.remoteSessionId,
            size: Constants.keysCount * Constants.keyLength
        ))

        var keysArray = [CZeroingData]()
        for i in 0..<Constants.keysCount {
            let offset = i * Constants.keyLength
            let zbuf = keysData.withOffset(offset, length: Constants.keyLength)
            keysArray.append(zbuf)
        }

        return CryptoKeys(
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

private struct PRFParameters {
    let label: String

    let secret: CZeroingData

    let clientSeed: CZeroingData

    let serverSeed: CZeroingData

    let clientSessionId: Data?

    let serverSessionId: Data?

    let size: Int
}

private extension DataPathWrapper.Parameters {
    func keysPRF(parameters: PRFParameters) throws -> CZeroingData {
        let seed = CZ(parameters.label, nullTerminated: false)
        seed.append(parameters.clientSeed)
        seed.append(parameters.serverSeed)
        if let csi = parameters.clientSessionId {
            seed.append(CZ(csi))
        }
        if let ssi = parameters.serverSessionId {
            seed.append(CZ(ssi))
        }
        let len = parameters.secret.length / 2
        let lenx = len + (parameters.secret.length & 1)
        let secret1 = parameters.secret.withOffset(0, length: lenx)
        let secret2 = parameters.secret.withOffset(len, length: lenx)

        let hash1 = try keysHash("md5", secret1, seed, parameters.size)
        let hash2 = try keysHash("sha1", secret2, seed, parameters.size)

        let prf = CZ()
        for i in 0..<hash1.length {
            let h1 = hash1.bytes[i]
            let h2 = hash2.bytes[i]

            prf.append(CZ(h1 ^ h2))
        }
        return prf
    }

    func keysHash(_ digestName: String, _ secret: CZeroingData, _ seed: CZeroingData, _ size: Int) throws -> CZeroingData {
        let out = CZ()
        let buffer = key_hmac_buf()
        var chain = try hmac(buffer, digestName, secret, seed)
        while out.length < size {
            out.append(try hmac(buffer, digestName, secret, chain.appending(seed)))
            chain = try hmac(buffer, digestName, secret, chain)
        }
        zd_free(buffer)
        return out.withOffset(0, length: size)
    }

    func hmac(
        _ buf: UnsafeMutablePointer<zeroing_data_t>,
        _ digestName: String,
        _ secret: CZeroingData,
        _ data: CZeroingData
    ) throws -> CZeroingData {
        var ctx = digestName.withCString { cDigest in
            key_hmac_ctx(
                dst: buf,
                digest_name: cDigest,
                secret: secret.ptr,
                data: data.ptr
            )
        }
        let hmacLength = key_hmac(&ctx);
        guard hmacLength > 0 else {
            throw DataPathError.wrapperKeys
        }
        return CZeroingData(
            bytes: buf.pointee.bytes,
            length: hmacLength
        )
    }
}
