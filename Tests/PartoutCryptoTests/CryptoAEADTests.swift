// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
import Testing

private let plainHex = "00112233ffddaa"
private let expectedEncryptedHex = "6c56b501472aae003fe988286ea3e72454d1dda1c2fd6c"
private nonisolated(unsafe) let cipherKey = CZeroingData(count: 32)
private nonisolated(unsafe) let hmacKey = CZeroingData(count: 32)
private let flags = CryptoFlags(
    iv: [0x56, 0x34, 0x12, 0x00],
    ad: [0x00, 0x12, 0x34, 0x56]
)
private let cryptoAEADCases: [(CryptoWrapper.Backend, String, Int, Int)] = {
    var cases: [(CryptoWrapper.Backend, String, Int, Int)] = []
#if PARTOUT_CRYPTO_OPENSSL
    cases.append((.openSSL, "aes-256-gcm", 16, 4))
#endif
#if PARTOUT_CRYPTO_MBEDTLS
    cases.append((.mbedTLS, "aes-256-gcm", 16, 4))
    cases.append((.native, "aes-256-gcm", 16, 4))
#endif
    return cases
}()

struct CryptoAEADTests {
    @Test(arguments: cryptoAEADCases)
    func givenData_whenEncrypt_thenDecrypts(backend: CryptoWrapper.Backend, cipherName: String, tagLength: Int, idLength: Int) throws {
        let sut = try CryptoWrapper(
            backend,
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
