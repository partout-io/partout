//
//  DataPathHMACTests.swift
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

final class DataPathHMACTests: XCTestCase, DataPathTestsProtocol {
    let peerId: UInt32 = 0x01

    let key: UInt8 = 0x02

    let packetId: UInt32 = 0x1020

    let payload = Data(hex: "11223344")
}

extension DataPathHMACTests {
    func test_givenHMAC_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptMock_thenDecrypts(CompressionFramingDisabled)
    }

    func test_givenHMACCompLZO_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptMock_thenDecrypts(CompressionFramingCompLZO)
    }

    func test_givenHMACCompress_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptMock_thenDecrypts(CompressionFramingCompress)
    }

    func test_givenHMACCompressV2_whenEncryptMock_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptMock_thenDecrypts(CompressionFramingCompressV2)
    }

    func test_givenHMAC_whenEncryptCBC_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBC_thenDecrypts(CompressionFramingDisabled)
    }

    func test_givenHMACCompLZO_whenEncryptCBC_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBC_thenDecrypts(CompressionFramingCompLZO)
    }

    func test_givenHMACCompress_whenEncryptCBC_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBC_thenDecrypts(CompressionFramingCompress)
    }

    func test_givenHMACCompressV2_whenEncryptCBC_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBC_thenDecrypts(CompressionFramingCompressV2)
    }

    func test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts(CompressionFramingDisabled)
    }

    func test_givenHMACCompLZO_whenEncryptCBCWithSHA1_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts(CompressionFramingCompLZO)
    }

    func test_givenHMACCompress_whenEncryptCBCWithSHA1_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts(CompressionFramingCompress)
    }

    func test_givenHMACCompressV2_whenEncryptCBCWithSHA1_thenDecrypts() throws {
        try private_test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts(CompressionFramingCompressV2)
    }
}

private extension DataPathHMACTests {
    func private_test_givenHMAC_whenEncryptMock_thenDecrypts(_ framing: compression_framing_t) throws {
        let mode = dp_mode_hmac_create_mock(framing)
        try testReversibleEncryption(mode: mode, payload: payload)
        try testReversibleCompoundEncryption(mode: mode, payload: payload)
        try testReversibleBulkEncryption(mode: mode)
        dp_mode_free(mode)
    }

    func private_test_givenHMAC_whenEncryptCBC_thenDecrypts(_ framing: compression_framing_t) throws {
        let mode = dp_mode_hmac_create_cbc(nil, "SHA1", framing)
        try testReversibleEncryption(mode: mode, payload: payload)
        try testReversibleCompoundEncryption(mode: mode, payload: payload)
        try testReversibleBulkEncryption(mode: mode)
        dp_mode_free(mode)
    }

    func private_test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts(_ framing: compression_framing_t) throws {
        let mode = dp_mode_hmac_create_cbc("AES-128-CBC", "SHA1", framing)
        try testReversibleEncryption(mode: mode, payload: payload)
        try testReversibleCompoundEncryption(mode: mode, payload: payload)
        try testReversibleBulkEncryption(mode: mode)
        dp_mode_free(mode)
    }
}
