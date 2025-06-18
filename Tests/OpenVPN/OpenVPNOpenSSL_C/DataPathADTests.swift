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
        try allFramings.forEach { framing in
            print("AD framing: \(framing)")
            let mode = dp_mode_ad_create_mock(framing)
            do {
                try testReversibleEncryption(
                    mode: mode,
                    assertAssembled: {
                        framing != CompressionFramingDisabled ||
                            $0.toHex() == self.payload.toHex()
                    },
                    assertEncrypted: {
                        framing != CompressionFramingDisabled ||
                            $0.toHex() == "4a00000100001020aabb44332211ccdd"
                    }
                )
                try testReversibleCompoundEncryption(
                    mode: mode,
                    assertEncrypted: {
                        framing != CompressionFramingDisabled ||
                            $0.toHex() == "4a00000100001020aabb44332211ccdd"
                    }
                )
            } catch {
                XCTFail("AD mock failed with framing: \(framing)")
                throw error
            }
        }
    }

    func test_givenAD_whenEncryptGCM_thenDecrypts() throws {
        let cipher = "AES-128-GCM"
        let tag = 8
        let id = 8
        try allFramings.forEach { framing in
            print("AD framing: \(framing)")
            do {
                let mode = dp_mode_ad_create_aead(cipher, tag, id, framing)
                try testReversibleEncryption(mode: mode)
                try testReversibleCompoundEncryption(mode: mode)
            } catch {
                XCTFail("AD \(cipher)/\(tag)/\(id) failed with framing: \(framing)")
                throw error
            }
        }
    }
}
