// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_STATIC
internal import _PartoutOpenVPNLegacy_ObjC
import PartoutCore
import PartoutOpenVPN
#endif

extension DataPathWrapper {
    static func legacy(
        with parameters: Parameters,
        prf: CryptoKeys.PRF,
        prng: PRNGProtocol
    ) throws -> DataPathWrapper {
        let keys = try CryptoKeys(withPRF: prf)
        return try .legacy(with: parameters, keys: keys, prng: prng)
    }

    static func legacy(
        with parameters: Parameters,
        keys: CryptoKeys,
        prng: PRNGProtocol
    ) throws -> DataPathWrapper {
        NSLog("PartoutOpenVPN: Using DataPathWrapper (legacy Swift/ObjC)")

        let seed = prng.data(length: Constants.DataChannel.prngSeedLength)
        guard let cryptoBox = OSSLCryptoBox(seed: Z(seed)) else {
            fatalError("Unable to create OSSLCryptoBox")
        }
        try cryptoBox.configure(
            with: OpenVPNCryptoOptions(
                cipherAlgorithm: parameters.cipher?.rawValue,
                digestAlgorithm: parameters.digest?.rawValue,
                cipherEncKey: keys.cipher.map { Z($0.encryptionKey.toData()) },
                cipherDecKey: keys.cipher.map { Z($0.decryptionKey.toData()) },
                hmacEncKey: keys.digest.map { Z($0.encryptionKey.toData()) },
                hmacDecKey: keys.digest.map { Z($0.decryptionKey.toData()) }
            )
        )

        let compressionFraming = parameters.compressionFraming
        let dataPath = DataPath(
            encrypter: cryptoBox.encrypter().dataPathEncrypter(),
            decrypter: cryptoBox.decrypter().dataPathDecrypter(),
            peerId: parameters.peerId ?? OpenVPNPacketPeerIdDisabled,
            compressionFraming: compressionFraming.legacyNative,
            compressionAlgorithm: .disabled,
            maxPackets: 100,
            usesReplayProtection: true
        )
        return DataPathWrapper(dataPath: dataPath)
    }
}

// MARK: -

extension DataPath: DataPathProtocol, DataPathLegacyProtocol {
    func encrypt(_ packets: [Data], key: UInt8) throws -> [Data] {
        try encryptPackets(packets, key: key)
    }

    func decrypt(_ packets: [Data]) throws -> (packets: [Data], keepAlive: Bool) {
        var keepAlive = false
        let packets = try decryptPackets(packets, keepAlive: &keepAlive)
        return (packets, keepAlive)
    }
}
