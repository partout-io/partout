// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable internal import PartoutPortable
import XCTest

final class CryptoPerformanceTests: XCTestCase {

    // 0.011 (ObjC = 0.032)
    func aes256gcm() throws {
        let sut = try CryptoWrapper(withAEADCipherName: "aes-256-gcm", tagLength: 16, idLength: 4)
        runMeasurement(crypto: sut)
    }

    // 0.025 (ObjC = 0.046)
    func aes256cbc() throws {
        let sut = try CryptoWrapper(withCBCCipherName: "aes-256-cbc", digestName: "sha-512")
        runMeasurement(crypto: sut)
    }

    // 0.021 (ObjC = 0.043)
    func aes256ctr() throws {
        let sut = try CryptoWrapper(withCTRCipherName: "aes-256-ctr", digestName: "sha-256", tagLength: 32, payloadLength: 17)
        runMeasurement(crypto: sut)
    }
}

private extension CryptoPerformanceTests {
    func runMeasurement(crypto: CryptoWrapper) {
        crypto.configureEncryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        crypto.configureDecryption(withCipherKey: cipherKey, hmacKey: hmacKey)
        let plainData = CZX("00112233ffddaa")
        let flags = CryptoFlags(iv: packetId, ad: ad)
        flags.withUnsafeFlags { flags in
            measure {
                for _ in 0...10000 {
                    do {
                        let encryptedData = try crypto.encryptData(plainData, flags: flags)
                        let returnedData = try crypto.decryptData(encryptedData, flags: flags)
                        #expect(returnedData, plainData)
                    } catch {
                        XCTFail("Cannot decrypt: \(error)")
                    }
                }
            }
        }
    }
}

extension CryptoPerformanceTests {
    var cipherKey: CZeroingData {
        CZeroingData(count: 64)
    }

    var hmacKey: CZeroingData {
        CZeroingData(count: 64)
    }

    var packetId: [UInt8] {
        [0x56, 0x34, 0x12, 0x00]
    }

    var ad: [UInt8] {
        [0x00, 0x12, 0x34, 0x56]
    }
}
