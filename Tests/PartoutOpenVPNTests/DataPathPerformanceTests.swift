// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutOpenVPN
import PartoutOS
import XCTest

final class DataPathPerformanceTests: XCTestCase {
    let peerId: UInt32 = 0x01

    let key: UInt8 = 0x02

    let packetId: UInt32 = 0x1020

    let payload = Data(hex: "11223344")

    let cryptoKeys = CryptoKeys(emptyWithCipherLength: 100, hmacKeyLength: 100)

    // MARK: - AD

    // 0.095
    func test_ad_aes256gcm_wrapped_native() throws {
        try private_testWrappedNative(cipher: .aes256gcm, digest: nil)
    }

    // MARK: HMAC

    // 0.275
    func test_hmac_wrapped_native_aes256cbc_sha512() throws {
        try private_testWrappedNative(cipher: .aes256cbc, digest: .sha512)
    }
}

// MARK: -

extension DataPathPerformanceTests {
    func private_testWrappedNative(cipher: OpenVPN.Cipher, digest: OpenVPN.Digest?) throws {
        let sut = try DataPathWrapper.native(
            with: .init(
                cipher: cipher,
                digest: digest,
                compressionFraming: .disabled,
                compressionAlgorithm: .disabled,
                peerId: nil
            ),
            keys: cryptoKeys
        )
        runMeasurement(dataPath: sut.dataPath)
    }

    func runMeasurement(dataPath: DataPathProtocol) {
        let payloads = (1...10).map { _ in
            Data(repeating: .random(in: 0...0xff), count: 50)
        }
        print("\tpayloads\t", payloads.map { $0.toHex() })
        measure {
            do {
                for _ in 0...10000 {
                    let encrypted = try dataPath.encrypt(payloads, key: key)
                    let decrypted = try dataPath.decrypt(encrypted).packets
                    XCTAssertEqual(decrypted, payloads)
                }
            } catch {
                XCTFail(error.localizedDescription)
            }
        }
    }
}
