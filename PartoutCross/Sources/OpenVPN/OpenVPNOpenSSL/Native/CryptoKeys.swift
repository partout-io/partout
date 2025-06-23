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

internal import _PartoutCryptoOpenSSL_C
import Foundation

struct CryptoKeys {
    struct KeyPair {
        let encryptionKey: CZeroingData

        let decryptionKey: CZeroingData
    }

    let cipher: KeyPair

    let digest: KeyPair
}

extension CryptoKeys {
    init(emptyWithCipherLength cipherKeyLength: Int, hmacKeyLength: Int) {
        cipher = KeyPair(
            encryptionKey: CZeroingData(length: cipherKeyLength),
            decryptionKey: CZeroingData(length: cipherKeyLength)
        )
        digest = KeyPair(
            encryptionKey: CZeroingData(length: hmacKeyLength),
            decryptionKey: CZeroingData(length: hmacKeyLength)
        )
    }
}

extension CryptoKeys {
    var cKeys: crypto_keys_t {
        crypto_keys_t(
            cipher: crypto_key_pair_t(
                enc_key: cipher.encryptionKey.ptr,
                dec_key: cipher.decryptionKey.ptr
            ),
            hmac: crypto_key_pair_t(
                enc_key: digest.encryptionKey.ptr,
                dec_key: digest.decryptionKey.ptr
            )
        )
    }
}
