// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
import XCTest

final class CryptoAEADTests: XCTestCase, CryptoFlagsProviding {
    func test_givenData_whenEncrypt_thenDecrypts() throws {
        let sut = try CryptoAEAD(cipherName: "aes-256-gcm", tagLength: 16, idLength: 4)

        sut.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        sut.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        let encryptedData: Data

        do {
            encryptedData = try withCryptoFlags {
                try sut.encryptData(plainData, flags: $0)
            }
        } catch {
            XCTFail("Cannot encrypt: \(error)")
            return
        }
        do {
            let returnedData = try withCryptoFlags {
                try sut.decryptData(encryptedData, flags: $0)
            }
            XCTAssertEqual(returnedData, plainData)
        } catch {
            XCTFail("Cannot decrypt: \(error)")
        }
    }
}

extension CryptoAEADTests {
    var cipherKey: ZeroingData {
        ZeroingData(length: 32)
    }

    var hmacKey: ZeroingData {
        ZeroingData(length: 32)
    }

    var plainData: Data {
        Data(hex: "00112233ffddaa")
    }

    var packetId: [UInt8] {
        [0x56, 0x34, 0x12, 0x00]
    }

    var ad: [UInt8] {
        [0x00, 0x12, 0x34, 0x56]
    }
}
