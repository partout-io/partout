// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCrypto_C
#if !PARTOUT_MONOLITH
import PartoutOS
#endif

extension CrossZD {
    // Must match HMACMaxLength in hmac.c
    private static let hmacMaxLength = 128

    static func forHMAC() -> CrossZD {
        CrossZD(count: hmacMaxLength)
    }

    func hmac(
        with digestName: String,
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
            return pp_hmac_do(&ctx)
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
