//
//  DataPathPerformanceTests.swift
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

import PartoutOpenVPN
@testable internal import PartoutOpenVPNCross
internal import PartoutOpenVPNLegacy_ObjC
import XCTest

final class DataPathPerformanceTests: XCTestCase {
    let peerId: UInt32 = 0x01

    let key: UInt8 = 0x02

    let packetId: UInt32 = 0x1020

    let payload = Data(hex: "11223344")

    let cryptoKeys = CryptoKeys(emptyWithCipherLength: 100, hmacKeyLength: 100)

    // MARK: - AD

    // 0.193
    func test_ad_legacy_aes256gcm() throws {
        try private_testLegacy(cipher: .aes256gcm, digest: nil)
    }

    // 0.196
    func test_ad_wrapped_legacy_aes256gcm() throws {
        try private_testWrappedLegacy(cipher: .aes256gcm, digest: nil)
    }

    // 0.095
    func test_ad_aes256gcm_wrapped_native() throws {
        try private_testWrappedNative(cipher: .aes256gcm, digest: nil)
    }

    // MARK: HMAC

    // 0.379
    func test_hmac_legacy_aes256cbc_sha512() throws {
        try private_testLegacy(cipher: .aes256cbc, digest: .sha512)
    }

    // 0.382
    func test_hmac_wrapped_legacy_aes256cbc_sha512() throws {
        try private_testWrappedLegacy(cipher: .aes256cbc, digest: .sha512)
    }

    // 0.275
    func test_hmac_wrapped_native_aes256cbc_sha512() throws {
        try private_testWrappedNative(cipher: .aes256cbc, digest: .sha512)
    }
}

// MARK: -

extension DataPathPerformanceTests {
    func private_testLegacy(cipher: OpenVPN.Cipher, digest: OpenVPN.Digest?) throws {
        let seed = Data(repeating: 0, count: 64)
        guard let cryptoBox = OSSLCryptoBox(seed: ZeroingData(data: seed)) else {
            fatalError("Unable to create OSSLCryptoBox")
        }
        try cryptoBox.configure(
            with: OpenVPNCryptoOptions(
                cipherAlgorithm: cipher.rawValue,
                digestAlgorithm: digest?.rawValue,
                cipherEncKey: cryptoKeys.cipher.map { Z($0.encryptionKey.toData()) },
                cipherDecKey: cryptoKeys.cipher.map { Z($0.decryptionKey.toData()) },
                hmacEncKey: cryptoKeys.digest.map { Z($0.encryptionKey.toData()) },
                hmacDecKey: cryptoKeys.digest.map { Z($0.decryptionKey.toData()) }
            )
        )
        let sut = DataPath(
            encrypter: cryptoBox.encrypter().dataPathEncrypter(),
            decrypter: cryptoBox.decrypter().dataPathDecrypter(),
            peerId: PacketPeerIdDisabled,
            compressionFraming: .disabled,
            compressionAlgorithm: .disabled,
            maxPackets: 1000,
            usesReplayProtection: true
        )
        runMeasurement(dataPath: sut)
    }

    func private_testWrappedLegacy(cipher: OpenVPN.Cipher, digest: OpenVPN.Digest?) throws {
        let sut = try DataPathWrapper.legacy(
            with: .init(
                cipher: cipher,
                digest: digest,
                compressionFraming: .disabled,
                peerId: nil
            ),
            keys: cryptoKeys,
            prng: PlatformPRNG()
        )
        runMeasurement(dataPath: sut.dataPath)
    }

    func private_testWrappedNative(cipher: OpenVPN.Cipher, digest: OpenVPN.Digest?) throws {
        let sut = try DataPathWrapper.native(
            with: .init(
                cipher: cipher,
                digest: digest,
                compressionFraming: .disabled,
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
