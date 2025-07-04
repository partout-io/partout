//
//  CryptoCTRTests.swift
//  Partout
//
//  Created by Davide De Rosa on 12/12/23.
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

@testable internal import _PartoutCryptoCore
import XCTest

final class CryptoCTRTests: XCTestCase, CryptoFlagsProviding {
    let plainData = Data(hex: "00112233ffddaa")

    let expectedEncryptedData = Data(hex: "2743c16b105670b350b6a5062224a0b691fb184c6d14dc0f39eed86aa04a1ca06b79108c65ed66")

    let cipherKey = CZeroingData(length: 32)

    let hmacKey = CZeroingData(length: 32)

    let packetId: [UInt8] = [0x56, 0x34, 0x12, 0x00]

    let ad: [UInt8] = [0x00, 0x12, 0x34, 0x56]

    func test_givenData_whenEncrypt_thenDecrypts() throws {
        let sut = try CryptoCTR(
            cipherName: "aes-128-ctr",
            digestName: "sha256",
            tagLength: 32,
            payloadLength: 128
        )
        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        withCryptoFlags { flags in
            let encryptedData: Data
            do {
                encryptedData = try sut.encryptData(self.plainData, flags: flags)
                print("encrypted: \(encryptedData.toHex())")
                print("expected : \(self.expectedEncryptedData.toHex())")
                XCTAssertEqual(encryptedData, self.expectedEncryptedData)
            } catch {
                XCTFail("Cannot encrypt: \(error)")
                return
            }
            do {
                let returnedData = try sut.decryptData(encryptedData, flags: flags)
                XCTAssertEqual(returnedData, self.plainData)
            } catch {
                XCTFail("Cannot decrypt: \(error)")
            }
        }
    }
}
