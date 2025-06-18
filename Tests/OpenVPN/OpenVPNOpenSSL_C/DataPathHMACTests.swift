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
        try allFramings.forEach { framing in
            let mode = dp_mode_hmac_create_mock(framing)
            do {
                try testReversibleEncryption(mode: mode)
                try testReversibleCompoundEncryption(mode: mode)
            } catch {
                XCTFail("HMAC mock failed with framing: \(framing)")
                throw error
            }
        }
    }

    func test_givenHMAC_whenEncryptCBC_thenDecrypts() throws {
        let cipher: String? = nil
        let digest = "SHA1"
        try allFramings.forEach { framing in
            print("HMAC framing: \(framing)")
            let mode = dp_mode_hmac_create_cbc(cipher, digest, framing)
            do {
                try testReversibleEncryption(mode: mode)
                try testReversibleCompoundEncryption(mode: mode)
            } catch {
                XCTFail("HMAC \(cipher ?? "none")/\(digest) failed with framing: \(framing)")
                throw error
            }
        }
    }

    func test_givenHMAC_whenEncryptCBCWithSHA1_thenDecrypts() throws {
        let cipher = "AES-128-CBC"
        let digest = "SHA1"
        try allFramings.forEach { framing in
            print("HMAC framing: \(framing)")
            let mode = dp_mode_hmac_create_cbc(cipher, digest, framing)
            do {
                try testReversibleEncryption(mode: mode)
                try testReversibleCompoundEncryption(mode: mode)
            } catch {
                XCTFail("HMAC \(cipher)/\(digest) failed with framing: \(framing)")
                throw error
            }
        }
    }
}
