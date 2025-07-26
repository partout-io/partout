//
//  CryptoWrapper+Data.swift
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

internal import _PartoutVendorsCryptoCore_C
internal import _PartoutVendorsPortable
import Foundation

extension CryptoWrapper {
    func encryptData(_ data: CZeroingData, flags: UnsafePointer<crypto_flags_t>?) throws -> CZeroingData {
        let dest = CZeroingData(count: data.count + 256)
        let destLength = try encryptBytes(
            data.bytes,
            length: data.count,
            dest: dest,
            flags: flags
        )
        dest.resize(toSize: destLength)
        return dest
    }
}

extension CryptoWrapper {
    func decryptData(_ data: CZeroingData, flags: UnsafePointer<crypto_flags_t>?) throws -> CZeroingData {
        let dest = CZeroingData(count: data.count + 256)
        let destLength = try decryptBytes(
            data.bytes,
            length: data.count,
            dest: dest,
            flags: flags
        )
        dest.resize(toSize: destLength)
        return dest
    }

    func verifyData(_ data: CZeroingData, flags: UnsafePointer<crypto_flags_t>?) throws {
        _ = try verifyBytes(data.bytes, length: data.count, flags: flags)
    }
}
