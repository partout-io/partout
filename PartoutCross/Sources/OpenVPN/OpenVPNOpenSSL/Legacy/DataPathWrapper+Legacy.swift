//
//  DataPathWrapper+Legacy.swift
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

import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_ObjC
import PartoutCore

private let PRNGSeedLength = 64

private let DataPathMaxPackets = 100

extension DataPathWrapper {
    static func legacy(
        with parameters: Parameters,
        prf: Parameters.PRF,
        prng: PRNGProtocol
    ) throws -> DataPathWrapper {
        NSLog("PartoutOpenVPN: Using DataPathWrapper (legacy Swift/ObjC)");

        guard let cipher = parameters.cipher,
              let digest = parameters.digest else {
            fatalError("Legacy OSSLCryptoBox requires both cipher/digest")
        }

        let seed = prng.safeData(length: PRNGSeedLength)
        guard let cryptoBox = OSSLCryptoBox(seed: Z(seed.toData())) else {
            fatalError("Unable to create OSSLCryptoBox")
        }
        try cryptoBox.configure(
            withCipher: cipher,
            digest: digest,
            handshake: prf.handshake,
            sessionId: prf.sessionId,
            remoteSessionId: prf.remoteSessionId
        )

        let compressionFraming = parameters.compressionFraming
        let dataPath = DataPath(
            encrypter: cryptoBox.encrypter(),
            decrypter: cryptoBox.decrypter(),
            peerId: parameters.peerId ?? PacketPeerIdDisabled,
            compressionFraming: compressionFraming.native,
            compressionAlgorithm: .disabled,
            maxPackets: DataPathMaxPackets,
            usesReplayProtection: Constants.usesReplayProtection
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
