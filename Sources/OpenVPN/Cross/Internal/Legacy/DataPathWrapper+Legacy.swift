// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import PartoutCore
import PartoutOpenVPN

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
            peerId: parameters.peerId ?? PacketPeerIdDisabled,
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

// MARK: -

extension DataPath: DataPathTestingProtocol {
    private static let zdSize = 64 * 1024

    // MARK: DataPathEncrypter

    func assemble(packetId: UInt32, payload: Data) -> Data {
        fatalError("FIXME: ###")
//        let zd = CZeroingData(length: Self.zdSize)
//        var length = 0
//        encrypter().assembleDataPacket(
//            assemblePayloadBlock(),
//            packetId: packetId,
//            payload: payload,
//            into: zd.ptr.pointee.bytes,
//            length: &length
//        )
//        return zd.toData(until: length)
    }

    func encrypt(key: UInt8, packetId: UInt32, assembled: Data) throws -> Data {
        fatalError("FIXME: ###")
//        try assembled.withUnsafeBytes { bytes in
//            try encrypter().encryptedDataPacket(
//                withKey: key,
//                packetId: packetId,
//                packetBytes: bytes.bytePointer,
//                packetLength: assembled.count
//            )
//        }
    }

    func assembleAndEncrypt(_ packet: Data, key: UInt8, packetId: UInt32) throws -> Data {
        fatalError("FIXME: ###")
    }

    // MARK: DataPathDecrypter

    func decrypt(packet: Data) throws -> DataPathDecryptedTuple {
        fatalError("FIXME: ###")
//        let zd = CZeroingData(length: Self.zdSize)
//        return try packet.withUnsafeBytes { bytes in
//            var length = 0
//            var packetId: UInt32 = 0
//            try decrypter().decryptDataPacket(
//                packet,
//                into: zd.ptr.pointee.bytes,
//                length: &length,
//                packetId: &packetId
//            )
//            let data = zd.toData(until: length)
//            return (packetId, data)
//        }
    }

    func parse(decrypted: Data, header: inout UInt8) throws -> Data {
        fatalError("FIXME: ###")
//        let zd = CZeroingData(length: Self.zdSize)
//        var header: UInt8 = 0
//        return try decrypter().parsePayload(
//            parsePayloadBlock(),
//            compressionHeader: &header,
//            packetBytes: zd.ptr.pointee.bytes,
//            packetLength: decrypted.count
//        )
    }

    func decryptAndParse(_ packet: Data) throws -> DataPathDecryptedAndParsedTuple {
        fatalError("FIXME: ###")
    }
}
