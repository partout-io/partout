//
//  Extensions.swift
//  Partout
//
//  Created by Davide De Rosa on 6/17/25.
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

internal import _PartoutCryptoOpenSSL_C
internal import _PartoutOpenVPNOpenSSL_C
import Foundation
import XCTest

/*
 Test matrix (separate files):

 - Mock
 - GCM
 - CBC

 Framing:

 - None
 - .compress
 - .compressV2
 - .compLZO
 */

protocol DataPathTestsProtocol where Self: XCTestCase {
    var peerId: UInt32 { get }

    var key: UInt8 { get }

    var packetId: UInt32 { get }

    var payload: Data { get }

    var allFramings: [compression_framing_t] { get }

    func testReversibleEncryption(
        mode: UnsafeMutablePointer<dp_mode_t>,
        assertAssembled: ((Data) -> Bool)?,
        assertEncrypted: ((Data) -> Bool)?
    ) throws

    func testReversibleCompoundEncryption(
        mode: UnsafeMutablePointer<dp_mode_t>,
        assertEncrypted: ((Data) -> Bool)?
    ) throws
}

extension DataPathTestsProtocol {
    var allFramings: [compression_framing_t] {[
        CompressionFramingDisabled,
        CompressionFramingCompLZO,
        CompressionFramingCompress,
        CompressionFramingCompressV2
    ]}

    func testReversibleEncryption(
        mode: UnsafeMutablePointer<dp_mode_t>,
        assertAssembled: ((Data) -> Bool)? = nil,
        assertEncrypted: ((Data) -> Bool)? = nil
    ) throws {
        let sut = DataPath(mode: mode, peerId: peerId)
        let crypto = mode.pointee.crypto.assumingMemoryBound(to: crypto_t.self)
        let cipherKeyLength = crypto.pointee.meta.cipher_key_len
        let hmacKeyLength = crypto.pointee.meta.hmac_key_len

        let cipherKey = Data(count: cipherKeyLength)
        let hmacKey = Data(count: hmacKeyLength)
        sut.configureEncryption(cipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(cipherKey: cipherKey, hmacKey: hmacKey)

        print("\tpayload\t\t", payload.toHex())

        let assembled = sut.assemble(packetId: packetId, payload: payload)
        print("\tassembled\t", assembled.toHex())
        if let assertAssembled {
            XCTAssertTrue(assertAssembled(assembled))
        }

        let encrypted = try sut.encrypt(key: key, packetId: packetId, assembled: assembled)
        print("\tencrypted\t", encrypted.toHex())

        // 4a = PacketCodeDataV2 and peer_id (1-byte)
        // 000001 = key (3-byte)
        // 00001020 = packet_id
        // encrypted payload
        if let assertEncrypted {
            XCTAssertTrue(assertEncrypted(encrypted))
        }

        let decryptedPair = try sut.decrypt(packet: encrypted)
        XCTAssertEqual(decryptedPair.0, packetId)
        XCTAssertEqual(decryptedPair.1, assembled)
        print("\tpacket_id:\t", String(format: "%0x", decryptedPair.0))
        print("\tdecrypted:\t", decryptedPair.1.toHex())

        let parsed = try sut.parse(decryptedPacket: decryptedPair.1)
        print("\tparsed:\t\t", parsed.toHex())
        XCTAssertEqual(parsed, payload)
    }

    func testReversibleCompoundEncryption(
        mode: UnsafeMutablePointer<dp_mode_t>,
        assertEncrypted: ((Data) -> Bool)? = nil
    ) throws {
        let sut = DataPath(mode: mode, peerId: peerId)
        let crypto = mode.pointee.crypto.assumingMemoryBound(to: crypto_t.self)
        let cipherKeyLength = crypto.pointee.meta.cipher_key_len
        let hmacKeyLength = crypto.pointee.meta.hmac_key_len

        let cipherKey = Data(count: cipherKeyLength)
        let hmacKey = Data(count: hmacKeyLength)
        sut.configureEncryption(cipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(cipherKey: cipherKey, hmacKey: hmacKey)

        print("\tpayload\t\t", payload.toHex())

        let encrypted = try sut.assembleAndEncrypt(
            payload,
            key: key,
            packetId: packetId,
            withNewBuffer: true
        )
        print("\tencrypted\t", encrypted.toHex())

        // 4a = PacketCodeDataV2 and peer_id (1-byte)
        // 000001 = key (3-byte)
        // 00001020 = packet_id
        // encrypted payload
        if let assertEncrypted {
            XCTAssertTrue(assertEncrypted(encrypted))
        }

        let decryptedPair = try sut.decryptAndParse(
            encrypted,
            withNewBuffer: true
        )
        XCTAssertEqual(decryptedPair.0, packetId)
        XCTAssertEqual(decryptedPair.1, payload)
        print("\tpacket_id:\t", String(format: "%0x", decryptedPair.0))
        print("\tdecrypted:\t", decryptedPair.1.toHex())
    }
}
