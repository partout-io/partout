//
//  CryptoKeys.swift
//  Partout
//
//  Created by Davide De Rosa on 6/20/25.
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

internal import _PartoutCryptoCore
internal import _PartoutCryptoCore_C
import Foundation

struct CryptoKeys {
    struct KeyPair {
        let encryptionKey: CZeroingData

        let decryptionKey: CZeroingData
    }

    let cipher: KeyPair?

    let digest: KeyPair?
}

extension CryptoKeys {
    init(emptyWithCipherLength cipherKeyLength: Int, hmacKeyLength: Int) {
        cipher = KeyPair(
            encryptionKey: CZeroingData(count: cipherKeyLength),
            decryptionKey: CZeroingData(count: cipherKeyLength)
        )
        digest = KeyPair(
            encryptionKey: CZeroingData(count: hmacKeyLength),
            decryptionKey: CZeroingData(count: hmacKeyLength)
        )
    }
}

final class CryptoKeysBridge {
    private let cipherEncKey: UnsafeMutablePointer<zeroing_data_t>

    private let cipherDecKey: UnsafeMutablePointer<zeroing_data_t>

    private let hmacEncKey: UnsafeMutablePointer<zeroing_data_t>

    private let hmacDecKey: UnsafeMutablePointer<zeroing_data_t>

    init(keys: CryptoKeys) {
        cipherEncKey = (keys.cipher?.encryptionKey).unsafeCopy()
        cipherDecKey = (keys.cipher?.decryptionKey).unsafeCopy()
        hmacEncKey = (keys.digest?.encryptionKey).unsafeCopy()
        hmacDecKey = (keys.digest?.decryptionKey).unsafeCopy()
    }

    deinit {
        zd_free(cipherEncKey)
        zd_free(cipherDecKey)
        zd_free(hmacEncKey)
        zd_free(hmacDecKey)
    }

    func withUnsafeKeys<T>(_ body: (UnsafePointer<crypto_keys_t>) -> T) -> T {
        withUnsafePointer(to: cKeys, body)
    }
}

private extension CryptoKeysBridge {
    var cKeys: crypto_keys_t {
        crypto_keys_t(
            cipher: crypto_key_pair_t(
                enc_key: cipherEncKey,
                dec_key: cipherDecKey
            ),
            hmac: crypto_key_pair_t(
                enc_key: hmacEncKey,
                dec_key: hmacDecKey
            )
        )
    }
}

private extension Optional<CZeroingData> {
    func unsafeCopy() -> UnsafeMutablePointer<zeroing_data_t> {
        guard let self else {
            return zd_create(0)
        }
        return zd_create_from_data(self.bytes, self.count)
    }
}
