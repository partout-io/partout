// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C

extension CrossZD {
    // Must match HMACMaxLength in hmac.c
    private static let hmacMaxLength = 128

    static func forHMAC() -> CrossZD {
        CrossZD(count: hmacMaxLength)
    }

    func hmac(
        _ fnt: pp_crypto_fnt,
        digestName: String,
        secret: CrossZD,
        data: CrossZD
    ) throws -> CrossZD {
        let hmacLength = digestName.withCString { cDigest in
            var ctx = pp_hmac_ctx(
                dst: mutableBytes,
                dst_len: count,
                digest_name: cDigest,
                secret: secret.mutableBytes,
                secret_len: secret.count,
                data: data.mutableBytes,
                data_len: data.count
            )
            return fnt.hmac_do(&ctx)
        }
        guard hmacLength > 0 else {
            throw PPCryptoError.hmac
        }
        return CrossZD(
            bytes: bytes,
            count: hmacLength
        )
    }
}
