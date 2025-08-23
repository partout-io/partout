// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCrypto_C
#if !PARTOUT_MONOLITH
internal import _PartoutOSPortable
#endif

extension CZeroingData {
    static func forHMAC() -> CZeroingData {
        CZeroingData(ptr: pp_hmac_create())
    }

    func hmac(
        with digestName: String,
        secret: CZeroingData,
        data: CZeroingData
    ) throws -> CZeroingData {
        let hmacLength = digestName.withCString { cDigest in
            var ctx = pp_hmac_ctx(
                dst: ptr,
                digest_name: cDigest,
                secret: secret.ptr,
                data: data.ptr
            )
            return pp_hmac_do(&ctx)
        }
        guard hmacLength > 0 else {
            throw PPCryptoError.hmac
        }
        return CZeroingData(
            bytes: ptr.pointee.bytes,
            count: hmacLength
        )
    }
}
