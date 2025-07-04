//
//  DataPathADTests.swift
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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
internal import _PartoutOpenVPN_C
@testable internal import _PartoutOpenVPN_Cross
import XCTest

final class DataPathADTests: XCTestCase, DataPathTestsProtocol {
    let peerId: UInt32 = 0x01

    let key: UInt8 = 0x02

    let packetId: UInt32 = 0x1020

    let payload = Data(hex: "11223344")
}

extension DataPathADTests {
    func test_givenAD_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(.disabled)
    }

    func test_givenADCompLZO_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(.compLZO)
    }

    func test_givenADCompress_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(.compress)
    }

    func test_givenADCompressV2_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(.compressV2)
    }

    func test_givenAD_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(.disabled)
    }

    func test_givenADCompLZO_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(.compLZO)
    }

    func test_givenADCompress_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(.compress)
    }

    func test_givenADCompressV2_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(.compressV2)
    }
}

extension DataPathADTests {
    func test_givenADCompressV2_whenEncryptMockWithNoCompressSwap_thenDecrypts() throws {
        try testMockFraming(.compressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(sut: $0, customPayloads: [
                Data([UInt8(DataPacketNoCompressSwap)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithLZOCompress_thenDecrypts() throws {
        try testMockFraming(.compressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(sut: $0, customPayloads: [
                Data([UInt8(DataPacketLZOCompress)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithV2Indicator_thenDecrypts() throws {
        try testMockFraming(.compressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(sut: $0, customPayloads: [
                Data([UInt8(DataPacketV2Indicator)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithV2Uncompressed_thenDecrypts() throws {
        try testMockFraming(.compressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(sut: $0, customPayloads: [
                Data([UInt8(DataPacketV2Uncompressed)])
            ]))
        }
    }
}

private extension DataPathADTests {
    func private_test_givenAD_whenEncryptMock_thenDecrypts(
        _ framing: OpenVPN.CompressionFraming
    ) throws {
        print("AD framing: \(framing)")
        let sut = DataPathWrapper.nativeADMock(with: framing).dataPath
        XCTAssertNoThrow(try testReversibleEncryption(sut: sut, payload: payload))
        XCTAssertNoThrow(try testReversibleCompoundEncryption(sut: sut, payload: payload))
        XCTAssertNoThrow(try testReversibleBulkEncryption(sut: sut))
    }

    func private_test_givenAD_whenEncryptGCM_thenDecrypts(
        _ framing: OpenVPN.CompressionFraming
    ) throws {
        print("AD framing: \(framing)")
        let keys = newEmptyKeys()
        let sut = try DataPathWrapper.native(with: .init(
            cipher: .aes128gcm,
            digest: nil,
            compressionFraming: framing,
            peerId: nil
        ), keys: keys).dataPath
        XCTAssertNoThrow(try testReversibleEncryption(sut: sut, payload: payload))
        XCTAssertNoThrow(try testReversibleCompoundEncryption(sut: sut, payload: payload))
        XCTAssertNoThrow(try testReversibleBulkEncryption(sut: sut))
    }

    func testMockFraming(_ framing: OpenVPN.CompressionFraming, block: (DataPathTestingProtocol) throws -> Void) throws {
        let subject = DataPathWrapper.nativeADMock(with: framing).dataPath
        try block(subject)
    }
}
