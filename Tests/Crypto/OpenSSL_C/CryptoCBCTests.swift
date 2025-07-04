//
//  CryptoCBCTests.swift
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

final class CryptoCBCTests: XCTestCase, CryptoFlagsProviding {
    let plainData = Data(hex: "00112233ffddaa")

    let plainHMACData = Data(hex: "8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa")

    let encryptedHMACData = Data(hex: "fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b")

    let cipherKey = CZeroingData(length: 32)

    let hmacKey = CZeroingData(length: 32)

    let packetId: [UInt8] = [0x56, 0x34, 0x12, 0x00]

    let ad: [UInt8] = [0x00, 0x12, 0x34, 0x56]

    func test_givenDecrypted_whenEncryptWithoutCipher_thenEncodesWithHMAC() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureEncryption(withCipherKey: nil, hmacKey: hmacKey)

        withCryptoFlags { flags in
            do {
                let returnedData = try sut.encryptData(self.plainData, flags: flags)
                print("plain   : \(returnedData.toHex())")
                print("expected: \(self.plainHMACData.toHex())")
                XCTAssertEqual(returnedData, self.plainHMACData)
            } catch {
                XCTFail("Cannot encrypt: \(error)")
            }
        }
    }

    func test_givenDecrypted_whenEncryptWithCipher_thenEncryptsWithHMAC() throws {
        let sut = try CryptoCBC(cipherName: "aes-128-cbc", digestName: "sha256")
        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        withCryptoFlags { flags in
            do {
                let returnedData = try sut.encryptData(self.plainData, flags: flags)
                print("encrypted: \(returnedData.toHex())")
                print("expected : \(self.encryptedHMACData.toHex())")
                XCTAssertEqual(returnedData, self.encryptedHMACData)
            } catch {
                XCTFail("Cannot encrypt: \(error)")
            }
        }
    }

    func test_givenEncodedWithHMAC_thenDecodes() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        withCryptoFlags { flags in
            do {
                let returnedData = try sut.decryptData(self.plainHMACData, flags: flags)
                print("decoded : \(returnedData.toHex())")
                print("expected: \(self.plainData.toHex())")
                XCTAssertEqual(returnedData, self.plainData)
            } catch {
                XCTFail("Cannot decrypt: \(error)")
            }
        }
    }

    func test_givenEncryptedWithHMAC_thenDecrypts() throws {
        let sut = try CryptoCBC(cipherName: "aes-128-cbc", digestName: "sha256")
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        withCryptoFlags { flags in
            do {
                let returnedData = try sut.decryptData(self.encryptedHMACData, flags: flags)
                print("decrypted: \(returnedData.toHex())")
                print("expected : \(self.plainData.toHex())")
                XCTAssertEqual(returnedData, self.plainData)
            } catch {
                XCTFail("Cannot decrypt: \(error)")
            }
        }
    }

    func test_givenHMAC_thenVerifies() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        try withCryptoFlags { flags in
            XCTAssertNoThrow(try sut.verifyData(self.plainHMACData, flags: flags))
            XCTAssertNoThrow(try sut.verifyData(self.encryptedHMACData, flags: flags))
        }
    }
}
