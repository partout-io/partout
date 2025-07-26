// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import _PartoutCryptoOpenSSL_ObjC
import XCTest

final class CryptoPerformanceTests: XCTestCase {

    // 0.032
    func test_aes256gcm() throws {
        let sut = try CryptoAEAD(cipherName: "aes-256-gcm", tagLength: 16, idLength: 4)
        runMeasurement(crypto: sut)
    }

    // 0.046
    func test_aes256cbc() throws {
        let sut = try CryptoCBC(cipherName: "aes-256-cbc", digestName: "sha-512")
        runMeasurement(crypto: sut)
    }

    // 0.043
    func test_aes256ctr() throws {
        let sut = try CryptoCTR(cipherName: "aes-256-ctr", digestName: "sha-256", tagLength: 32, payloadLength: 17)
        runMeasurement(crypto: sut)
    }
}

private extension CryptoPerformanceTests {
    func runMeasurement(crypto: Encrypter & Decrypter) {
        crypto.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        crypto.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        let plainData = Data(hex: "00112233ffddaa")
        withCryptoFlags { flags in
            measure {
                for _ in 0...10000 {
                    do {
                        let encryptedData = try crypto.encryptData(plainData, flags: flags)
                        let returnedData = try crypto.decryptData(encryptedData, flags: flags)
                        XCTAssertEqual(returnedData, plainData)
                    } catch {
                        XCTFail("Cannot decrypt: \(error)")
                    }
                }
            }
        }
    }
}

extension CryptoPerformanceTests: CryptoFlagsProviding {
    var cipherKey: ZeroingData {
        ZeroingData(length: 64)
    }

    var hmacKey: ZeroingData {
        ZeroingData(length: 64)
    }

    var packetId: [UInt8] {
        [0x56, 0x34, 0x12, 0x00]
    }

    var ad: [UInt8] {
        [0x00, 0x12, 0x34, 0x56]
    }
}
