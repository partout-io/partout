// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import _PartoutCryptoOpenSSL_ObjC
#endif
import Foundation

func Z() -> ZeroingData {
    ZeroingData()
}

func Z(length: Int) -> ZeroingData {
    ZeroingData(length: length)
}

func Z(bytes: UnsafePointer<UInt8>, length: Int) -> ZeroingData {
    ZeroingData(bytes: bytes, length: length)
}

func Z(_ uint8: UInt8) -> ZeroingData {
    ZeroingData(uInt8: uint8)
}

func Z(_ uint16: UInt16) -> ZeroingData {
    ZeroingData(uInt16: uint16)
}

func Z(_ data: Data) -> ZeroingData {
    ZeroingData(data: data)
}

func Z(_ data: Data, _ offset: Int, _ length: Int) -> ZeroingData {
    ZeroingData(data: data, offset: offset, length: length)
}

func Z(_ string: String, nullTerminated: Bool) -> ZeroingData {
    ZeroingData(string: string, nullTerminated: nullTerminated)
}
