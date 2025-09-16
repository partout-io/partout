// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutOS
import Foundation
import Testing

private let plainHex = "00112233ffddaa"
private let plainHMACHex = "8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa"
private let encryptedHMACHex = "fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b"
private nonisolated(unsafe) let cipherKey = CZeroingData(length: 32)
private nonisolated(unsafe) let hmacKey = CZeroingData(length: 32)
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
            print("\(id):encrypted: \(returnedData.toHex())")
            print("\(id):expected : \(expected)")
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
