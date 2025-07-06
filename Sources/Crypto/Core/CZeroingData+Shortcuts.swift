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

import Foundation

public func CZ() -> CZeroingData {
    CZeroingData(count: 0)
}

public func CZ(count: Int) -> CZeroingData {
    CZeroingData(count: count)
}

public func CZ(bytes: UnsafePointer<UInt8>, length: Int) -> CZeroingData {
    CZeroingData(bytes: bytes, length: length)
}

public func CZ(_ uint8: UInt8) -> CZeroingData {
    CZeroingData(uInt8: uint8)
}

public func CZ(_ uint16: UInt16) -> CZeroingData {
    CZeroingData(uInt16: uint16)
}

public func CZ(_ data: Data) -> CZeroingData {
    CZeroingData(data: data)
}

public func CZ(_ data: Data, _ offset: Int, _ length: Int) -> CZeroingData {
    CZeroingData(data: data, offset: offset, length: length)
}

public func CZ(_ string: String, nullTerminated: Bool) -> CZeroingData {
    CZeroingData(string: string, nullTerminated: nullTerminated)
}

public func CZ(_ native: CZeroingData) -> CZeroingData {
    native
}

// TODO: ###, drop middle Data
public func CZX(_ hex: String) -> CZeroingData {
    CZ(Data(hex: hex))
}
