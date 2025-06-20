//
//  DataPathTestsProtocol.swift
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

import _PartoutOpenVPN
@testable import _PartoutOpenVPNOpenSSL
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
}

extension DataPathTestsProtocol {
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

        let decryptedTuple = try sut.decrypt(packet: encrypted)
        XCTAssertEqual(decryptedTuple.packetId, packetId)
        XCTAssertEqual(decryptedTuple.data, assembled)
        print("\tpacket_id:\t", String(format: "%0x", decryptedTuple.packetId))
        print("\tdecrypted:\t", decryptedTuple.data.toHex())

        var header: UInt8 = .zero
        let parsed = try sut.parse(decrypted: decryptedTuple.data, header: &header)
        print("\tparsed:\t\t", parsed.toHex())
        XCTAssertEqual(parsed, payload)
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
            XCTAssertTrue(assertEncrypted(encrypted))
        }

        let decryptedTuple = try sut.decryptAndParse(encrypted)
        XCTAssertEqual(decryptedTuple.packetId, packetId)
        XCTAssertEqual(decryptedTuple.data, payload)
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
        let payloads = customPayloads ?? (1...10).map {
            Data(repeating: .random(in: 0...0xff), count: .random(in: 1...$0))
        }
        print("\tpayloads\t", payloads.map { $0.toHex() })

        let encrypted = try sut.encrypt(payloads, key: key)
        print("\tencrypted\t", encrypted.map { $0.toHex() })

        let decrypted = try sut.decrypt(encrypted).packets
        print("\tdecrypted\t", decrypted.map { $0.toHex() })

        XCTAssertEqual(decrypted, payloads)
    }
}

extension DataPathTestsProtocol {
    var emptyKeys: DataPathWrapper.Parameters.Keys {
        .init(
            cipher: .init(encryptionKey: CZ(), decryptionKey: CZ()),
            digest: .init(encryptionKey: CZ(), decryptionKey: CZ())
        )
    }

    func sut(
        cipher: OpenVPN.Cipher?,
        digest: OpenVPN.Digest,
        framing: OpenVPN.CompressionFraming,
        peerId: UInt32 = 0
    ) -> DataPathTestingProtocol {
        do {
            return try DataPathWrapper.native(
                with: .init(
                    cipher: cipher,
                    digest: digest,
                    compressionFraming: framing,
                    peerId: peerId
                ),
                keys: emptyKeys
            ).dataPath
        } catch {
            XCTFail("Could not create sut: \(error)")
            fatalError(error.localizedDescription)
        }
    }
}
