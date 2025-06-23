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

internal import _PartoutCryptoOpenSSL_Cross
import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import PartoutCore

private let PRNGSeedLength = 64

private let CryptoAEADTagLength = 16

private let CryptoAEADIdLength = PacketIdLength

private let CryptoCTRTagLength = 32

private let CryptoCTRPayloadLength = PacketOpcodeLength + PacketSessionIdLength + PacketReplayIdLength + PacketReplayTimestampLength

extension DataPathWrapper {
    static func native(with parameters: Parameters, prf: Parameters.PRF, prng: PRNGProtocol) throws -> DataPathWrapper {
        let seed = prng.safeData(length: PRNGSeedLength)
        return try .native(with: parameters, prf: prf, seed: seed)
    }

    static func native(with parameters: Parameters, prf: Parameters.PRF, seed: CZeroingData) throws -> DataPathWrapper {
        seed.useToInitializeKeys()
        return try .native(with: parameters, keys: parameters.keys(with: prf))
    }

    static func native(with parameters: Parameters, keys: CryptoKeys) throws -> DataPathWrapper {
        print("PartoutOpenVPN: Using DataPathWrapper (native Swift/C)");

        let mode: UnsafeMutablePointer<dp_mode_t>
        let cipherAlgorithm = parameters.cipher?.rawValue.uppercased()
        let digestAlgorithm = parameters.digest?.rawValue.uppercased()
        let keysBridge = CryptoKeysBridge(keys: keys)

        if let cipherAlgorithm, cipherAlgorithm.hasSuffix("-GCM") {
            mode = withUnsafePointer(to: keysBridge.cKeys) { keys in
                cipherAlgorithm.withCString { cCipher in
                    dp_mode_ad_create_aead(
                        cCipher,
                        CryptoAEADTagLength,
                        CryptoAEADIdLength,
                        keys,
                        parameters.compressionFraming.cNative
                    )
                }
            }
        } else {
            guard let digestAlgorithm else {
                throw DataPathError.wrapperAlgorithm
            }
            mode = digestAlgorithm.withCString { cDigest in
                withUnsafePointer(to: keysBridge.cKeys) { keys in
                    if let cipherAlgorithm {
                        return cipherAlgorithm.withCString { cCipher in
                            dp_mode_hmac_create_cbc(
                                cCipher,
                                cDigest,
                                keys,
                                parameters.compressionFraming.cNative
                            )
                        }
                    } else {
                        return dp_mode_hmac_create_cbc(
                            nil,
                            cDigest,
                            keys,
                            parameters.compressionFraming.cNative
                        )
                    }
                }
            }
        }

        // the encryption keys must match the cipher/digest
        let crypto = mode.pointee.crypto.assumingMemoryBound(to: crypto_t.self)
        let cipherKeyLength = crypto.pointee.meta.cipher_key_len
        let hmacKeyLength = crypto.pointee.meta.hmac_key_len

        assert(keys.cipher.encryptionKey.length >= cipherKeyLength)
        assert(keys.cipher.decryptionKey.length >= cipherKeyLength)
        assert(keys.digest.encryptionKey.length >= hmacKeyLength)
        assert(keys.digest.decryptionKey.length >= hmacKeyLength)

        return try cNative(with: mode, peerId: parameters.peerId)
    }
}

extension DataPathWrapper {
    static func nativeADMock(with framing: OpenVPN.CompressionFraming) throws -> DataPathWrapper {
        let mode = dp_mode_ad_create_mock(framing.cNative)
        return try cNative(with: mode, peerId: nil)
    }

    static func nativeHMACMock(with framing: OpenVPN.CompressionFraming) throws -> DataPathWrapper {
        let mode = dp_mode_hmac_create_mock(framing.cNative)
        return try cNative(with: mode, peerId: nil)
    }
}

private extension DataPathWrapper {
    static func cNative(
        with mode: UnsafeMutablePointer<dp_mode_t>,
        peerId: UInt32?
    ) throws -> DataPathWrapper {
        let dataPath = CDataPath(mode: mode, peerId: peerId ?? PacketPeerIdDisabled)
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
