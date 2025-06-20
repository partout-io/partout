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

internal import _PartoutCryptoOpenSSL_C
internal import _PartoutOpenVPNOpenSSL_C
import PartoutCore
import XCTest

final class DataPathADTests: XCTestCase, DataPathTestsProtocol {
    let peerId: UInt32 = 0x01

    let key: UInt8 = 0x02

    let packetId: UInt32 = 0x1020

    let payload = Data(hex: "11223344")
}

extension DataPathADTests {
    func test_givenAD_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(CompressionFramingDisabled)
    }

    func test_givenADCompLZO_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(CompressionFramingCompLZO)
    }

    func test_givenADCompress_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(CompressionFramingCompress)
    }

    func test_givenADCompressV2_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptMock_thenDecrypts(CompressionFramingCompressV2)
    }

    func test_givenAD_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(CompressionFramingDisabled)
    }

    func test_givenADCompLZO_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(CompressionFramingCompLZO)
    }

    func test_givenADCompress_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(CompressionFramingCompress)
    }

    func test_givenADCompressV2_whenEncryptGCM_thenDecrypts() throws {
        try private_test_givenAD_whenEncryptGCM_thenDecrypts(CompressionFramingCompressV2)
    }
}

extension DataPathADTests {
    func test_givenADCompressV2_whenEncryptMockWithNoCompressSwap_thenDecrypts() throws {
        try testFraming(CompressionFramingCompressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(mode: $0, customPayloads: [
                Data([UInt8(DataPacketNoCompressSwap)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithLZOCompress_thenDecrypts() throws {
        try testFraming(CompressionFramingCompressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(mode: $0, customPayloads: [
                Data([UInt8(DataPacketLZOCompress)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithV2Indicator_thenDecrypts() throws {
        try testFraming(CompressionFramingCompressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(mode: $0, customPayloads: [
                Data([UInt8(DataPacketV2Indicator)])
            ]))
        }
    }

    func test_givenADCompressV2_whenEncryptMockWithV2Uncompressed_thenDecrypts() throws {
        try testFraming(CompressionFramingCompressV2) {
            XCTAssertNoThrow(try testReversibleBulkEncryption(mode: $0, customPayloads: [
                Data([UInt8(DataPacketV2Uncompressed)])
            ]))
        }
    }

    private func testFraming(_ framing: compression_framing_t, _ block: (UnsafeMutablePointer<dp_mode_t>) throws -> Void) rethrows {
        let mode = dp_mode_ad_create_mock(framing)
        try block(mode)
        dp_mode_free(mode)
    }
}

private extension DataPathADTests {
    func private_test_givenAD_whenEncryptMock_thenDecrypts(
        _ framing: compression_framing_t
    ) throws {
        print("AD framing: \(framing)")
        let mode = dp_mode_ad_create_mock(framing)
        XCTAssertNoThrow(try testReversibleEncryption(mode: mode, payload: payload))
        XCTAssertNoThrow(try testReversibleCompoundEncryption(mode: mode, payload: payload))
        XCTAssertNoThrow(try testReversibleBulkEncryption(mode: mode))
        dp_mode_free(mode)
    }

    func private_test_givenAD_whenEncryptGCM_thenDecrypts(
        _ framing: compression_framing_t
    ) throws {
        let cipher = "AES-128-GCM"
        let tag = 8
        let id = 8
        print("AD framing: \(framing)")
        let mode = dp_mode_ad_create_aead(cipher, tag, id, framing)
        XCTAssertNoThrow(try testReversibleEncryption(mode: mode, payload: payload))
        XCTAssertNoThrow(try testReversibleCompoundEncryption(mode: mode, payload: payload))
        XCTAssertNoThrow(try testReversibleBulkEncryption(mode: mode))
        dp_mode_free(mode)
    }
}
