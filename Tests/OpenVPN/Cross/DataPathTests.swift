// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutOpenVPN
internal import _PartoutOpenVPN_C
@testable internal import PartoutOpenVPNCross
import Foundation
import Testing

private func cryptoFree(_: pp_crypto_ctx) {
}

private let peerId: UInt32 = 0x01
private let key: UInt8 = 0x02
private let packetId: UInt32 = 0x1020
private let payload = Data(hex: "11223344")

struct DataPathTests {
    @Test(arguments: [
        // mock AD
        (nil as OpenVPN.Cipher?, nil as OpenVPN.Digest?, OpenVPN.CompressionFraming.disabled),
        (nil, nil, .compLZO),
        (nil, nil, .compress),
        (nil, nil, .compressV2),
        // mock HMAC
        (nil, .sha1, OpenVPN.CompressionFraming.disabled),
        (nil, .sha1, .compLZO),
        (nil, .sha1, .compress),
        (nil, .sha1, .compressV2),
        // GCM
        (.aes128gcm, nil, .disabled),
        (.aes128gcm, nil, .compLZO),
        (.aes128gcm, nil, .compress),
        (.aes128gcm, nil, .compressV2),
        // CBC
        (nil, .sha256, .disabled),
        (nil, .sha256, .compLZO),
        (nil, .sha256, .compress),
        (nil, .sha256, .compressV2),
        (.aes128cbc, .sha256, .disabled),
        (.aes128cbc, .sha256, .compLZO),
        (.aes128cbc, .sha256, .compress),
        (.aes128cbc, .sha256, .compressV2)
    ])
    func givenPayload_whenEncrypt_thenDecrypts(
        cipher: OpenVPN.Cipher?,
        digest: OpenVPN.Digest?,
        framing: OpenVPN.CompressionFraming
    ) throws {
        let mode: UnsafeMutablePointer<openvpn_dp_mode>
        switch cipher {
        case .aes128gcm:
            precondition(cipher != nil)
            let keys = CryptoKeys(emptyWithCipherLength: 1024, hmacKeyLength: 1024)
            let cryptoAEAD = CryptoKeysBridge(keys: keys).withUnsafeKeys { keys in
                pp_crypto_aead_create(cipher!.rawValue, 16, 4, keys)
            }
            guard let cryptoAEAD else {
                throw PPCryptoError.creation
            }
            mode = openvpn_dp_mode_ad_create(cryptoAEAD, cryptoFree, framing.cNative)
        case .aes128cbc:
            precondition(digest != nil)
            let keys = CryptoKeys(emptyWithCipherLength: 1024, hmacKeyLength: 1024)
            let cryptoCBC = CryptoKeysBridge(keys: keys).withUnsafeKeys { keys in
                pp_crypto_cbc_create(cipher?.rawValue, digest!.rawValue, keys)
            }
            guard let cryptoCBC else {
                throw PPCryptoError.creation
            }
            mode = openvpn_dp_mode_hmac_create(cryptoCBC, cryptoFree, framing.cNative)
        default:
            if digest != nil {
                mode = openvpn_dp_mode_hmac_create_mock(framing.cNative)
            } else {
                mode = openvpn_dp_mode_ad_create_mock(framing.cNative)
            }
        }
        let sut = CDataPath(mode: mode, peerId: peerId)

        try testReversibleEncryption(sut: sut, payload: payload)
        try testReversibleCompoundEncryption(sut: sut, payload: payload)
        try testReversibleBulkEncryption(sut: sut)
    }

    @Test(arguments: [
        UInt8(OpenVPNDataPacketNoCompressSwap),
        UInt8(OpenVPNDataPacketLZOCompress),
        UInt8(OpenVPNDataPacketV2Indicator),
        UInt8(OpenVPNDataPacketV2Uncompressed)
    ])
    func givenMagicPacket_whenEncryptMockCompressV2_thenDecrypts(byte: UInt8) throws {
        let mode = openvpn_dp_mode_ad_create_mock(OpenVPN.CompressionFraming.compressV2.cNative)
        let sut = CDataPath(mode: mode, peerId: peerId)
        try testReversibleBulkEncryption(sut: sut, customPayloads: [
            Data([byte])
        ])
    }
}

private extension DataPathTests {
    func testReversibleEncryption(
        sut: DataPathTestingProtocol,
        payload: Data,
        assertAssembled: ((Data) -> Bool)? = nil,
        assertEncrypted: ((Data) -> Bool)? = nil
    ) throws {
        print("\tpayload\t\t", payload.toHex())

        let assembled = sut.assemble(packetId: packetId, payload: payload)
        print("\tassembled\t", assembled.toHex())
        if let assertAssembled {
            #expect(assertAssembled(assembled))
        }

        let encrypted = try sut.encrypt(key: key, packetId: packetId, assembled: assembled)
        print("\tencrypted\t", encrypted.toHex())

        // 4a = PacketCodeDataV2 and peer_id (1-byte)
        // 000001 = key (3-byte)
        // 00001020 = packet_id
        // encrypted payload
        if let assertEncrypted {
            #expect(assertEncrypted(encrypted))
        }

        let decryptedTuple = try sut.decrypt(packet: encrypted)
        #expect(decryptedTuple.packetId == packetId)
        #expect(decryptedTuple.data == assembled)
        print("\tpacket_id:\t", String(format: "%0x", decryptedTuple.packetId))
        print("\tdecrypted:\t", decryptedTuple.data.toHex())

        var header: UInt8 = .zero
        let parsed = try sut.parse(decrypted: decryptedTuple.data, header: &header)
        print("\tparsed:\t\t", parsed.toHex())
        #expect(parsed == payload)
    }

    func testReversibleCompoundEncryption(
        sut: DataPathTestingProtocol,
        payload: Data,
        assertEncrypted: ((Data) -> Bool)? = nil
    ) throws {
        print("\tpayload\t\t", payload.toHex())

        let encrypted = try sut.assembleAndEncrypt(
            payload,
            key: key,
            packetId: packetId
        )
        print("\tencrypted\t", encrypted.toHex())

        // 4a = PacketCodeDataV2 and peer_id (1-byte)
        // 000001 = key (3-byte)
        // 00001020 = packet_id
        // encrypted payload
        if let assertEncrypted {
            #expect(assertEncrypted(encrypted))
        }

        let decryptedTuple = try sut.decryptAndParse(encrypted)
        #expect(decryptedTuple.packetId == packetId)
        #expect(decryptedTuple.data == payload)
        print("\tpacket_id:\t", String(format: "%0x", decryptedTuple.packetId))
        print("\theader:\t\t", String(format: "%0x", decryptedTuple.header))
        print("\tdecrypted:\t", decryptedTuple.data.toHex())
    }

    func testReversibleBulkEncryption(
        sut: DataPathTestingProtocol,
        customPayloads: [Data]? = nil
    ) throws {

        //
        // N = 10 packets with:
        //
        // - random length in [1, N]
        // - repeating random byte in [0, 0xff]
        //
        // a ping packet would be discarded and spoil the tests, but it's
        // impossible to obtain randomically because the generated bytes
        // are repeating
        //
        let payloads = customPayloads ?? (1...10).map {
            Data(repeating: .random(in: 0...0xff), count: .random(in: 1...$0))
        }
        print("\tpayloads\t", payloads.map { $0.toHex() })

        let encrypted = try sut.encrypt(payloads, key: key)
        print("\tencrypted\t", encrypted.map { $0.toHex() })

        let decrypted = try sut.decrypt(encrypted).packets
        print("\tdecrypted\t", decrypted.map { $0.toHex() })

        #expect(decrypted == payloads)
    }
}
