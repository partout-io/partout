// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
import XCTest

final class CryptoCBCTests: XCTestCase, CryptoFlagsProviding {
    func test_givenDecrypted_whenEncryptWithoutCipher_thenEncodesWithHMAC() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureEncryption(withCipherKey: nil, hmacKey: hmacKey)

        do {
            let returnedData = try withCryptoFlags {
                try sut.encryptData(plainData, flags: $0)
            }
            XCTAssertEqual(returnedData, plainHMACData)
        } catch {
            XCTFail("Cannot encrypt: \(error)")
        }
    }

    func test_givenDecrypted_whenEncryptWithCipher_thenEncryptsWithHMAC() throws {
        let sut = try CryptoCBC(cipherName: "aes-128-cbc", digestName: "sha256")
        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        do {
            let returnedData = try withCryptoFlags {
                try sut.encryptData(plainData, flags: $0)
            }
            XCTAssertEqual(returnedData, encryptedHMACData)
        } catch {
            XCTFail("Cannot encrypt: \(error)")
        }
    }

    func test_givenEncodedWithHMAC_thenDecodes() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        do {
            let returnedData = try withCryptoFlags {
                try sut.decryptData(plainHMACData, flags: $0)
            }
            XCTAssertEqual(returnedData, plainData)
        } catch {
            XCTFail("Cannot decrypt: \(error)")
        }
    }

    func test_givenEncryptedWithHMAC_thenDecrypts() throws {
        let sut = try CryptoCBC(cipherName: "aes-128-cbc", digestName: "sha256")
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)

        do {
            let returnedData = try withCryptoFlags {
                try sut.decryptData(encryptedHMACData, flags: $0)
            }
            XCTAssertEqual(returnedData, plainData)
        } catch {
            XCTFail("Cannot decrypt: \(error)")
        }
    }

    func test_givenHMAC_thenVerifies() throws {
        let sut = try CryptoCBC(cipherName: nil, digestName: "sha256")
        sut.configureDecryption(withCipherKey: nil, hmacKey: hmacKey)

        try withCryptoFlags {
            XCTAssertNoThrow(try sut.verifyData(plainHMACData, flags: $0))
            XCTAssertNoThrow(try sut.verifyData(encryptedHMACData, flags: $0))
        }
    }
}

extension CryptoCBCTests {
    var cipherKey: ZeroingData {
        ZeroingData(length: 32)
    }

    var hmacKey: ZeroingData {
        ZeroingData(length: 32)
    }

    var plainData: Data {
        Data(hex: "00112233ffddaa")
    }

    var plainHMACData: Data {
        Data(hex: "8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa")
    }

    var encryptedHMACData: Data {
        Data(hex: "fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b")
    }

    var packetId: [UInt8] {
        [0x56, 0x34, 0x12, 0x00]
    }

    var ad: [UInt8] {
        [0x00, 0x12, 0x34, 0x56]
    }
}
