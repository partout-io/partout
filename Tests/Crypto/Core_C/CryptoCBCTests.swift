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
import Foundation
import Testing

private let plainData = Data(hex: "00112233ffddaa")
private let plainHMACData = Data(hex: "8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa")
private let encryptedHMACData = Data(hex: "fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b")
private let cipherKey = CZeroingData(length: 32)
private let hmacKey = CZeroingData(length: 32)
private let flags = CryptoFlags(
    packetId: [0x56, 0x34, 0x12, 0x00],
    ad: [0x00, 0x12, 0x34, 0x56]
)

struct CryptoCBCTests {
    @Test(arguments: [
        (nil, "sha256", plainHMACData),
        ("aes-128-cbc", "sha256", encryptedHMACData)
    ])
    func givenDecrypted_whenEncrypt_thenEncodes(cipherName: String?, digestName: String, expected: Data) throws {
        let sut = try CryptoCBC(cipherName: cipherName, digestName: digestName)
        sut.configureEncryption(withCipherKey: cipherName != nil ? cipherKey : nil, hmacKey: hmacKey)

        let id = "\(cipherName ?? "nil"):\(digestName)"
        try flags.withUnsafeFlags { flags in
            let returnedData = try sut.encryptData(plainData, flags: flags)
            print("\(id):plain   : \(returnedData.toHex())")
            print("\(id):expected: \(expected.toHex())")
            #expect(returnedData == expected)
        }
    }

    @Test(arguments: [
        (nil, "sha256", plainHMACData, plainData),
        ("aes-128-cbc", "sha256", encryptedHMACData, plainData)
    ])
    func givenEncryptedWithHMAC_thenDecrypts(cipherName: String?, digestName: String, encrypted: Data, expected: Data) throws {
        let sut = try CryptoCBC(cipherName: cipherName, digestName: digestName)
        sut.configureDecryption(withCipherKey: cipherName != nil ? cipherKey : nil, hmacKey: hmacKey)

        let id = "\(cipherName ?? "nil"):\(digestName)"
        try flags.withUnsafeFlags { flags in
            let returnedData = try sut.decryptData(encrypted, flags: flags)
            print("\(id):decoded : \(returnedData.toHex())")
            print("\(id):expected: \(expected.toHex())")
            #expect(returnedData == expected)
        }
    }

    @Test(arguments: [
        ("sha256", plainHMACData),
        ("sha256", encryptedHMACData)
    ])
    func givenHMAC_thenVerifies(digestName: String, encrypted: Data) throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: digestName)
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        try flags.withUnsafeFlags { flags in
            try sut.verifyData(encrypted, flags: flags)
        }
    }
}
