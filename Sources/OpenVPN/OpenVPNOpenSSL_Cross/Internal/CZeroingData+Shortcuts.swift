//
//  CZeroingData+Shortcuts.swift
//  Partout
//
//  Created by Davide De Rosa on 1/8/25.
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

internal import _PartoutCryptoOpenSSL_Cross
import Foundation

func CZ() -> CZeroingData {
    CZeroingData()
}

func CZ(length: Int) -> CZeroingData {
    CZeroingData(length: length)
}

func CZ(bytes: UnsafePointer<UInt8>, length: Int) -> CZeroingData {
    CZeroingData(bytes: bytes, length: length)
}

func CZ(_ uint8: UInt8) -> CZeroingData {
    CZeroingData(uInt8: uint8)
}

func CZ(_ uint16: UInt16) -> CZeroingData {
    CZeroingData(uInt16: uint16)
}

func CZ(_ data: Data) -> CZeroingData {
    CZeroingData(data: data)
}

func CZ(_ data: Data, _ offset: Int, _ length: Int) -> CZeroingData {
    CZeroingData(data: data, offset: offset, length: length)
}

func CZ(_ string: String, nullTerminated: Bool) -> CZeroingData {
    CZeroingData(string: string, nullTerminated: nullTerminated)
}

// to compile in full native mode
func CZ(_ native: CZeroingData) -> CZeroingData {
    native
}

#if canImport(_PartoutCryptoOpenSSL_ObjC)
internal import _PartoutCryptoOpenSSL_ObjC

private extension CZeroingData {
    convenience init(_ legacy: ZeroingData) {
        self.init(bytes: legacy.bytes, length: legacy.length)
    }
}

func CZ(_ legacy: ZeroingData) -> CZeroingData {
    CZeroingData(legacy)
}
#endif
