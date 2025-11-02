// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutOpenVPN_ObjC
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension OpenVPNCryptoProtocol {
    func configure(
        withCipher cipher: OpenVPN.Cipher,
        digest: OpenVPN.Digest,
        auth: LegacyHandshake,
        sessionId: Data,
        remoteSessionId: Data
    ) throws {
        let ks = try keySet(
            auth: auth,
            sessionId: sessionId,
            remoteSessionId: remoteSessionId
        )
        let cryptoOptions = OpenVPNCryptoOptions(
            cipherAlgorithm: cipher.rawValue,
            digestAlgorithm: digest.rawValue,
            cipherEncKey: ks.cipherEncKey,
            cipherDecKey: ks.cipherDecKey,
            hmacEncKey: ks.hmacEncKey,
            hmacDecKey: ks.hmacDecKey
        )
        try configure(with: cryptoOptions)
    }

    func encrypter() -> DataPathEncrypter {
        return encrypter().dataPathEncrypter()
    }

    func decrypter() -> DataPathDecrypter {
        return decrypter().dataPathDecrypter()
    }
}

// MARK: - Helpers

private let maxHmacLength = 100

private struct PRFParameters {
    let label: String

    let secret: LegacyZD

    let clientSeed: LegacyZD

    let serverSeed: LegacyZD

    let clientSessionId: Data?

    let serverSessionId: Data?

    let size: Int
}

private struct KeySet {
    let cipherEncKey: LegacyZD

    let cipherDecKey: LegacyZD

    let hmacEncKey: LegacyZD

    let hmacDecKey: LegacyZD
}

private extension OpenVPNCryptoProtocol {
    func keySet(
        auth: LegacyHandshake,
        sessionId: Data,
        remoteSessionId: Data
    ) throws -> KeySet {
        let masterData = try keysPRF(parameters: .init(
            label: Constants.Keys.label1,
            secret: auth.preMaster,
            clientSeed: auth.random1,
            serverSeed: auth.serverRandom1,
            clientSessionId: nil,
            serverSessionId: nil,
            size: Constants.Keys.preMasterLength
        ))
        let keysData = try keysPRF(parameters: .init(
            label: Constants.Keys.label2,
            secret: masterData,
            clientSeed: auth.random2,
            serverSeed: auth.serverRandom2,
            clientSessionId: sessionId,
            serverSessionId: remoteSessionId,
            size: Constants.Keys.keysCount * Constants.Keys.keyLength
        ))

        var keysArray = [LegacyZD]()
        for i in 0..<Constants.Keys.keysCount {
            let offset = i * Constants.Keys.keyLength
            let zbuf = keysData.withOffset(offset, length: Constants.Keys.keyLength)
            keysArray.append(zbuf)
        }

        let cipherEncKey = keysArray[0]
        let hmacEncKey = keysArray[1]
        let cipherDecKey = keysArray[2]
        let hmacDecKey = keysArray[3]

        return .init(
            cipherEncKey: cipherEncKey,
            cipherDecKey: cipherDecKey,
            hmacEncKey: hmacEncKey,
            hmacDecKey: hmacDecKey
        )
    }

    func keysPRF(parameters: PRFParameters) throws -> LegacyZD {
        let seed = Z(parameters.label, nullTerminated: false)
        seed.append(parameters.clientSeed)
        seed.append(parameters.serverSeed)
        if let csi = parameters.clientSessionId {
            seed.append(Z(csi))
        }
        if let ssi = parameters.serverSessionId {
            seed.append(Z(ssi))
        }
        let len = parameters.secret.length / 2
        let lenx = len + (parameters.secret.length & 1)
        let secret1 = parameters.secret.withOffset(0, length: lenx)
        let secret2 = parameters.secret.withOffset(len, length: lenx)

        let hash1 = try keysHash("md5", secret1, seed, parameters.size)
        let hash2 = try keysHash("sha1", secret2, seed, parameters.size)

        let prf = Z()
        for i in 0..<hash1.length {
            let h1 = hash1.bytes[i]
            let h2 = hash2.bytes[i]

            prf.append(Z(h1 ^ h2))
        }
        return prf
    }

    func keysHash(_ digestName: String, _ secret: LegacyZD, _ seed: LegacyZD, _ size: Int) throws -> LegacyZD {
        let out = Z()
        let buffer = Z(length: maxHmacLength)
        var chain = try hmac(buffer, digestName, secret, seed)
        while out.length < size {
            out.append(try hmac(buffer, digestName, secret, chain.appending(seed)))
            chain = try hmac(buffer, digestName, secret, chain)
        }
        return out.withOffset(0, length: size)
    }

    func hmac(_ buffer: LegacyZD, _ digestName: String, _ secret: LegacyZD, _ data: LegacyZD) throws -> LegacyZD {
        var length = 0

        try hmac(
            withDigestName: digestName,
            secret: secret.bytes,
            secretLength: secret.length,
            data: data.bytes,
            dataLength: data.length,
            hmac: buffer.mutableBytes,
            hmacLength: &length
        )

        return buffer.withOffset(0, length: length)
    }
}
