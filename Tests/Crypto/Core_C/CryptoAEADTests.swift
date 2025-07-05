//
//  CryptoAEADTests.swift
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
import Foundation
import Testing

private let plainHex = "00112233ffddaa"
private let expectedEncryptedHex = "6c56b501472aae003fe988286ea3e72454d1dda1c2fd6c"
private let cipherKey = CZeroingData(length: 32)
private let hmacKey = CZeroingData(length: 32)
private let flags = CryptoFlags(
    packetId: [0x56, 0x34, 0x12, 0x00],
    ad: [0x00, 0x12, 0x34, 0x56]
)

struct CryptoAEADTests {
    @Test(arguments: [
        ("aes-256-gcm", 16, 4)
    ])
    func givenData_whenEncrypt_thenDecrypts(cipherName: String, tagLength: Int, idLength: Int) throws {
        let sut = try CryptoAEAD(
            cipherName: cipherName,
            tagLength: tagLength,
            idLength: idLength
        )
        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        try flags.withUnsafeFlags { flags in
            let encryptedData = try sut.encryptData(Data(hex: plainHex), flags: flags)
            print("encrypted: \(encryptedData.toHex())")
            print("expected : \(expectedEncryptedHex)")
            #expect(encryptedData.toHex() == expectedEncryptedHex)

            let returnedData = try sut.decryptData(encryptedData, flags: flags)
            #expect(returnedData.toHex() == plainHex)
        }
    }
}
