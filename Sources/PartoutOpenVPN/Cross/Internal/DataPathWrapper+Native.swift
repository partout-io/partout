// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutOpenVPN_C
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

extension DataPathWrapper {
    static func native(with parameters: Parameters, prf: CryptoKeys.PRF, prng: PRNGProtocol) throws -> DataPathWrapper {
        let seed = prng.data(length: Constants.DataChannel.prngSeedLength)
        return try .native(with: parameters, prf: prf, seed: CZ(seed))
    }

    static func native(with parameters: Parameters, prf: CryptoKeys.PRF, seed: CrossZD) throws -> DataPathWrapper {
        pp_crypto_init_seed_zd(seed.ptr)
        let keys = try CryptoKeys(withPRF: prf)
        return try .native(with: parameters, keys: keys)
    }

    static func native(with parameters: Parameters, keys: CryptoKeys) throws -> DataPathWrapper {
        NSLog("PartoutOpenVPN: Using DataPathWrapper (native Swift/C)")

        let mode: UnsafeMutablePointer<openvpn_dp_mode>?
        let cipherAlgorithm = parameters.cipher?.rawValue.uppercased()
        let digestAlgorithm = parameters.digest?.rawValue.uppercased()
        let keysBridge = CryptoKeysBridge(keys: keys)

        if let cipherAlgorithm, cipherAlgorithm.hasSuffix("-GCM") {
            mode = keysBridge.withUnsafeKeys { keys in
                cipherAlgorithm.withCString { cCipher in
                    openvpn_dp_mode_ad_create_aead(
                        cCipher,
                        Constants.DataChannel.aeadTagLength,
                        Constants.DataChannel.aeadIdLength,
                        keys,
                        parameters.compressionFraming.cNative
                    )
                }
            }
        } else {
            guard let digestAlgorithm else {
                throw OpenVPNDataPathError.algorithm
            }
            mode = try digestAlgorithm.withCString { cDigest in
                try keysBridge.withUnsafeKeys { keys in
                    if let cipherAlgorithm {
                        return try cipherAlgorithm.withCString { cCipher in
                            let mode = openvpn_dp_mode_hmac_create_cbc(
                                cCipher,
                                cDigest,
                                keys,
                                parameters.compressionFraming.cNative
                            )
                            guard let mode else {
                                throw OpenVPNDataPathError.algorithm
                            }
                            return mode
                        }
                    } else {
                        return openvpn_dp_mode_hmac_create_cbc(
                            nil,
                            cDigest,
                            keys,
                            parameters.compressionFraming.cNative
                        )
                    }
                }
            }
        }

        guard let mode else {
            throw OpenVPNDataPathError.creation
        }

        // the encryption keys must match the cipher/digest
        let crypto = mode.pointee.crypto.assumingMemoryBound(to: pp_crypto.self)
        let cipherKeyLength = crypto.pointee.meta.cipher_key_len
        let hmacKeyLength = crypto.pointee.meta.hmac_key_len

        if let cipher = keys.cipher {
            assert(cipher.encryptionKey.count >= cipherKeyLength)
            assert(cipher.decryptionKey.count >= cipherKeyLength)
        }
        if let digest = keys.digest {
            assert(digest.encryptionKey.count >= hmacKeyLength)
            assert(digest.decryptionKey.count >= hmacKeyLength)
        }
        return cNative(with: mode, peerId: parameters.peerId)
    }
}

extension DataPathWrapper {
    static func nativeADMock(with framing: OpenVPN.CompressionFraming) -> DataPathWrapper {
        let mode = openvpn_dp_mode_ad_create_mock(framing.cNative)
        return cNative(with: mode, peerId: nil)
    }

    static func nativeHMACMock(with framing: OpenVPN.CompressionFraming) -> DataPathWrapper {
        let mode = openvpn_dp_mode_hmac_create_mock(framing.cNative)
        return cNative(with: mode, peerId: nil)
    }
}

private extension DataPathWrapper {
    static func cNative(
        with mode: UnsafeMutablePointer<openvpn_dp_mode>,
        peerId: UInt32?
    ) -> DataPathWrapper {
        let dataPath = CDataPath(mode: mode, peerId: peerId ?? OpenVPNPacketPeerIdDisabled)
        return DataPathWrapper(dataPath: dataPath)
    }
}

// MARK: -

extension CDataPath: DataPathProtocol {
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

extension OpenVPN.CompressionFraming {
    var cNative: openvpn_compression_framing {
        switch self {
        case .disabled: OpenVPNCompressionFramingDisabled
        case .compLZO: OpenVPNCompressionFramingCompLZO
        case .compress: OpenVPNCompressionFramingCompress
        case .compressV2: OpenVPNCompressionFramingCompressV2
        @unknown default: OpenVPNCompressionFramingDisabled
        }
    }
}
