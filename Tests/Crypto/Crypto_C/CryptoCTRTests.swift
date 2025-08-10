// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import _PartoutVendorsPortable
import Foundation
import Testing

private let plainHex = "00112233ffddaa"
private let expectedEncryptedHex = "2743c16b105670b350b6a5062224a0b691fb184c6d14dc0f39eed86aa04a1ca06b79108c65ed66"
private let cipherKey = CZeroingData(count: 32)
private let hmacKey = CZeroingData(count: 32)
private let flags = CryptoFlags(
    ad: [0x00, 0x12, 0x34, 0x56]
)

struct CryptoCTRTests {
    @Test(arguments: [
        ("aes-128-ctr", "sha256", 32, 128)
    ])
    func givenData_whenEncrypt_thenDecrypts(cipherName: String, digestName: String, tagLength: Int, payloadLength: Int) throws {
        let sut = try CryptoWrapper(
            withCTRCipherName: cipherName,
            digestName: digestName,
            tagLength: tagLength,
            payloadLength: payloadLength
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
