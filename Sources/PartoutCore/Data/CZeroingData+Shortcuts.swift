// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public func CZ() -> CZeroingData {
    CZeroingData(count: 0)
}

public func CZ(count: Int) -> CZeroingData {
    CZeroingData(count: count)
}

public func CZ(bytes: UnsafePointer<UInt8>, count: Int) -> CZeroingData {
    CZeroingData(bytes: bytes, count: count)
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

public func CZ(_ data: Data, _ offset: Int, _ count: Int) -> CZeroingData {
    CZeroingData(data: data, offset: offset, count: count)
}

public func CZ(_ string: String, nullTerminated: Bool) -> CZeroingData {
    CZeroingData(string: string, nullTerminated: nullTerminated)
}

public func CZ(_ native: CZeroingData) -> CZeroingData {
    native
}

public func CZX(_ hex: String) -> CZeroingData {
    CZeroingData(hex: hex)
}
