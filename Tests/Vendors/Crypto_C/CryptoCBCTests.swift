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

@testable internal import _PartoutVendorsPortable
import Foundation
import Testing

private let plainHex = "00112233ffddaa"
private let plainHMACHex = "8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa"
private let encryptedHMACHex = "fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b"
private let cipherKey = CZeroingData(count: 32)
private let hmacKey = CZeroingData(count: 32)
private let flags = CryptoFlags()

struct CryptoCBCTests {
    @Test(arguments: [
        (nil as String?, "sha256", plainHMACHex),
        ("aes-128-cbc", "sha256", encryptedHMACHex)
    ])
    func givenDecrypted_whenEncrypt_thenIsExpected(cipherName: String?, digestName: String, expected: String) throws {
        let sut = try CryptoWrapper(withCBCCipherName: cipherName, digestName: digestName)
        sut.configureEncryption(withCipherKey: cipherName != nil ? cipherKey : nil, hmacKey: hmacKey)

        let id = "\(cipherName ?? "nil"):\(digestName)"
        try flags.withUnsafeFlags { flags in
            let returnedData = try sut.encryptData(CZX(plainHex), flags: flags)
            NSLog("\(id):encrypted: \(returnedData.toHex())")
            NSLog("\(id):expected : \(expected)")
            #expect(returnedData.toHex() == expected)
        }
    }

    @Test(arguments: [
        (nil as String?, "sha256", plainHMACHex, plainHex),
        ("aes-128-cbc", "sha256", encryptedHMACHex, plainHex)
    ])
    func givenEncryptedWithHMAC_whenDecrypt_thenIsExpected(cipherName: String?, digestName: String, encrypted: String, expected: String) throws {
        let sut = try CryptoWrapper(withCBCCipherName: cipherName, digestName: digestName)
        sut.configureDecryption(withCipherKey: cipherName != nil ? cipherKey : nil, hmacKey: hmacKey)

        let id = "\(cipherName ?? "nil"):\(digestName)"
        try flags.withUnsafeFlags { flags in
            let returnedData = try sut.decryptData(CZX(encrypted), flags: flags)
            print("\(id):decrypted : \(returnedData.toHex())")
            print("\(id):expected : \(expected)")
            #expect(returnedData.toHex() == expected)
        }
    }

    @Test(arguments: [
        ("sha256", plainHMACHex),
        ("sha256", encryptedHMACHex)
    ])
    func givenHMAC_whenVerify_thenSucceeds(digestName: String, encrypted: String) throws {
        let sut = try CryptoWrapper(withCBCCipherName: nil, digestName: digestName)
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        try flags.withUnsafeFlags { flags in
            try sut.verifyData(CZX(encrypted), flags: flags)
        }
    }
}
