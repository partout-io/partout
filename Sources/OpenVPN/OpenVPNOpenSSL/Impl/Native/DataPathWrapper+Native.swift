//
//  DataPathWrapper+Native.swift
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
import PartoutCore

// FIXME: ###, wrapper supersedes OSSLCryptoBox, delete later

private let PRNGSeedLength = 64

private let CryptoAEADTagLength = 16

private let CryptoAEADIdLength = PacketIdLength

private let CryptoCTRTagLength = 32

private let CryptoCTRPayloadLength = PacketOpcodeLength + PacketSessionIdLength + PacketReplayIdLength + PacketReplayTimestampLength

extension DataPathWrapper {
    static func native(with parameters: Parameters, prf: Parameters.PRF, prng: PRNGProtocol) throws -> DataPathWrapper {
        let seed = CZ(prng.safeData(length: PRNGSeedLength))
        return try .native(with: parameters, prf: prf, seed: seed)
    }

    static func native(with parameters: Parameters, prf: Parameters.PRF, seed: CZeroingData) throws -> DataPathWrapper {
        key_init_seed(seed.ptr)
        return try .native(with: parameters, keys: parameters.keys(with: prf))
    }

    static func native(with parameters: Parameters, keys: Parameters.Keys) throws -> DataPathWrapper {
        NSLog("PartoutOpenVPN: Using DataPathWrapper (native Swift/C)");

        let mode: UnsafeMutablePointer<dp_mode_t>
        let cipherAlgorithm = parameters.cipher?.rawValue.uppercased()
        let digestAlgorithm = parameters.digest?.rawValue.uppercased()

        if let cipherAlgorithm, cipherAlgorithm.hasSuffix("-GCM") {
            mode = cipherAlgorithm.withCString { cCipher in
                dp_mode_ad_create_aead(
                    cCipher,
                    CryptoAEADTagLength,
                    CryptoAEADIdLength,
                    parameters.compressionFraming.cNative
                )
            }
        } else {
            guard let digestAlgorithm else {
                throw DataPathError.wrapperAlgorithm
            }
            mode = digestAlgorithm.withCString { cDigest in
                if let cipherAlgorithm {
                    return cipherAlgorithm.withCString { cCipher in
                        dp_mode_hmac_create_cbc(
                            cCipher,
                            cDigest,
                            parameters.compressionFraming.cNative
                        )
                    }
                } else {
                    return dp_mode_hmac_create_cbc(
                        nil,
                        cDigest,
                        parameters.compressionFraming.cNative
                    )
                }
            }
        }

        return try cNative(with: mode, peerId: parameters.peerId, keys: keys)
    }
}

extension DataPathWrapper {
    static func nativeADMock(with framing: OpenVPN.CompressionFraming, keys: Parameters.Keys) throws -> DataPathWrapper {
        let mode = dp_mode_ad_create_mock(framing.cNative)
        return try cNative(with: mode, peerId: nil, keys: keys)
    }

    static func nativeHMACMock(with framing: OpenVPN.CompressionFraming, keys: Parameters.Keys) throws -> DataPathWrapper {
        let mode = dp_mode_hmac_create_mock(framing.cNative)
        return try cNative(with: mode, peerId: nil, keys: keys)
    }
}

private extension DataPathWrapper {
    static func cNative(
        with mode: UnsafeMutablePointer<dp_mode_t>,
        peerId: UInt32?,
        keys: Parameters.Keys
    ) throws -> DataPathWrapper {
        let dataPath = CDataPath(mode: mode, peerId: peerId ?? PacketPeerIdDisabled)
        dataPath.configureEncryption(
            cipherKey: keys.cipher.encryptionKey.ptr,
            hmacKey: keys.digest.encryptionKey.ptr
        )
        dataPath.configureDecryption(
            cipherKey: keys.cipher.decryptionKey.ptr,
            hmacKey: keys.digest.decryptionKey.ptr
        )
        return DataPathWrapper(dataPath: dataPath)
    }
}

// MARK: -

extension CDataPath: DataPathProtocol, DataPathLegacyProtocol {
    func encryptPackets(_ packets: [Data], key: UInt8) throws -> [Data] {
        try encrypt(packets, key: key)
    }

    func decryptPackets(_ packets: [Data], keepAlive: UnsafeMutablePointer<Bool>?) throws -> [Data] {
        let result = try decrypt(packets)
        keepAlive?.pointee = result.keepAlive
        return result.packets
    }
}

extension CDataPath: DataPathTestingProtocol {
    func assembleAndEncrypt(_ packet: Data, key: UInt8, packetId: UInt32) throws -> Data {
        try assembleAndEncrypt(packet, key: key, packetId: packetId, buf: nil)
    }

    func decryptAndParse(_ packet: Data) throws -> DataPathDecryptedAndParsedTuple {
        try decryptAndParse(packet, buf: nil)
    }
}

// MARK: -

private extension OpenVPN.CompressionFraming {
    var cNative: compression_framing_t {
        switch self {
        case .disabled: CompressionFramingDisabled
        case .compLZO: CompressionFramingCompLZO
        case .compress: CompressionFramingCompress
        case .compressV2: CompressionFramingCompressV2
        @unknown default: CompressionFramingDisabled
        }
    }
}
