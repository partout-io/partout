//
//  CZeroingData+HMAC.swift
//  Partout
//
//  Created by Davide De Rosa on 6/23/25.
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

extension CZeroingData {
    static func forHMAC() -> CZeroingData {
        CZeroingData(ptr: key_hmac_create())
    }

    func hmac(
        with digestName: String,
        secret: CZeroingData,
        data: CZeroingData
    ) throws -> CZeroingData {
        let hmacLength = digestName.withCString { cDigest in
            var ctx = key_hmac_ctx(
                dst: ptr,
                digest_name: cDigest,
                secret: secret.ptr,
                data: data.ptr
            )
            return key_hmac_do(&ctx)
        }
        guard hmacLength > 0 else {
            throw CryptoError.hmac
        }
        return CZeroingData(
            bytes: ptr.pointee.bytes,
            count: hmacLength
        )
    }
}
