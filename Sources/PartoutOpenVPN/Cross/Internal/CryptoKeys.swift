// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCrypto_C
#if !PARTOUT_MONOLITH
internal import PartoutPortable
#endif
import PartoutPortable_C
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
    private let cipherEncKey: UnsafeMutablePointer<pp_zd>

    private let cipherDecKey: UnsafeMutablePointer<pp_zd>

    private let hmacEncKey: UnsafeMutablePointer<pp_zd>

    private let hmacDecKey: UnsafeMutablePointer<pp_zd>

    init(keys: CryptoKeys) {
        cipherEncKey = (keys.cipher?.encryptionKey).unsafeCopy()
        cipherDecKey = (keys.cipher?.decryptionKey).unsafeCopy()
        hmacEncKey = (keys.digest?.encryptionKey).unsafeCopy()
        hmacDecKey = (keys.digest?.decryptionKey).unsafeCopy()
    }

    deinit {
        pp_zd_free(cipherEncKey)
        pp_zd_free(cipherDecKey)
        pp_zd_free(hmacEncKey)
        pp_zd_free(hmacDecKey)
    }

    func withUnsafeKeys<T>(_ body: (UnsafePointer<pp_crypto_keys>) -> T) -> T {
        withUnsafePointer(to: cKeys, body)
    }
}

private extension CryptoKeysBridge {
    var cKeys: pp_crypto_keys {
        pp_crypto_keys(
            cipher: pp_crypto_key_pair(
                enc_key: cipherEncKey,
                dec_key: cipherDecKey
            ),
            hmac: pp_crypto_key_pair(
                enc_key: hmacEncKey,
                dec_key: hmacDecKey
            )
        )
    }
}

private extension Optional<CZeroingData> {
    func unsafeCopy() -> UnsafeMutablePointer<pp_zd> {
        guard let self else {
            return pp_zd_create(0)
        }
        return pp_zd_create_from_data(self.bytes, self.count)
    }
}
