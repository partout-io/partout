// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Foundation
import Testing

private let plainHex = "00112233ffddaa"
private let expectedEncryptedHex = "6c56b501472aae003fe988286ea3e72454d1dda1c2fd6c"
private nonisolated(unsafe) let cipherKey = CZeroingData(count: 32)
private nonisolated(unsafe) let hmacKey = CZeroingData(count: 32)
private let flags = CryptoFlags(
    iv: [0x56, 0x34, 0x12, 0x00],
    ad: [0x00, 0x12, 0x34, 0x56]
)

struct CryptoAEADTests {
    @Test(arguments: [
        ("aes-256-gcm", 16, 4)
    ])
    func givenData_whenEncrypt_thenDecrypts(cipherName: String, tagLength: Int, idLength: Int) throws {
        let sut = try CryptoWrapper(
            withAEADCipherName: cipherName,
            tagLength: tagLength,
            idLength: idLength
        )
        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        try flags.withUnsafeFlags { flags in
            let encryptedData = try sut.encryptData(CZX(plainHex), flags: flags)
            print("encrypted: \(encryptedData.toHex())")
            print("expected : \(expectedEncryptedHex)")
            #expect(encryptedData.toHex() == expectedEncryptedHex)

            let returnedData = try sut.decryptData(encryptedData, flags: flags)
            #expect(returnedData.toHex() == plainHex)
        }
    }
}
