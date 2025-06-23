//
//  CZeroingData.swift
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
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

internal import _PartoutCryptoOpenSSL_C
import Foundation

final class CZeroingData {
    let ptr: UnsafeMutablePointer<zeroing_data_t>

    private init(ptr: UnsafeMutablePointer<zeroing_data_t>) {
        self.ptr = ptr
    }

    init(length: Int = 0) {
        self.ptr = zd_create(length)
    }

    init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.ptr = zd_create_from_data(bytes, length)
    }

    init(uInt8: UInt8) {
        var value = uInt8
        self.ptr = zd_create_from_data(&value, 1)
    }

    init(uInt16: UInt16) {
        var value = uInt16
        ptr = withUnsafeBytes(of: &value) {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return zd_create_from_data(bytes, 2)
        }
    }

    init(data: Data) {
        ptr = data.withUnsafeBytes {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return zd_create_from_data(bytes, data.count)
        }
    }

    init(data: Data, offset: Int, length: Int) {
        ptr = data.withUnsafeBytes {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return zd_create_from_data_range(bytes, offset, length)
        }
    }

    init(string: String, nullTerminated: Bool) {
        guard let cstr = string.cString(using: .utf8) else {
            ptr = zd_create(0)
            return
        }
        self.ptr = zd_create_from_string(cstr, nullTerminated)
    }

    deinit {
        zd_free(ptr)
    }
}

// MARK: Properties

extension CZeroingData {
    var bytes: UnsafePointer<UInt8>! {
        zd_bytes(ptr)
    }

    var mutableBytes: UnsafeMutablePointer<UInt8>! {
        zd_mutable_bytes(ptr)
    }

    var length: Int {
        zd_length(ptr)
    }
}

extension CZeroingData: Equatable {
    static func == (lhs: CZeroingData, rhs: CZeroingData) -> Bool {
        zd_equals(lhs.ptr, rhs.ptr)
    }

    func isEqual(to data: Data) -> Bool {
        let length = data.count
        return data.withUnsafeBytes { dataPtr in
            zd_equals_to_data(ptr, dataPtr.bytePointer, length)
        }
    }
}

// MARK: Copy

extension CZeroingData {
    func copy() -> CZeroingData {
        CZeroingData(ptr: zd_make_copy(self.ptr))
    }

    func withOffset(_ offset: Int, length: Int) -> CZeroingData {
        guard let slice = zd_make_slice(ptr, offset, length) else {
            return CZeroingData()
        }
        return CZeroingData(ptr: slice)
    }

    func appending(_ other: CZeroingData) -> CZeroingData {
        let copy = zd_make_copy(ptr)
        zd_append(copy, other.ptr)
        return CZeroingData(ptr: copy)
    }
}

// MARK: Side effect

extension CZeroingData {
    func zero() {
        zd_zero(ptr)
    }

    func truncate(toSize size: Int) {
        zd_resize(ptr, size)
    }

    func remove(untilOffset offset: Int) {
        zd_remove_until(ptr, offset)
    }

    func append(_ other: CZeroingData) {
        zd_append(ptr, other.ptr)
    }
}

// MARK: Accessors

extension CZeroingData {
    func networkUInt16Value(fromOffset offset: Int) -> UInt16 {
        CFSwapInt16BigToHost(zd_uint16(ptr, offset))
    }

    func nullTerminatedString(fromOffset offset: Int) -> String? {
        precondition(offset <= length)
        guard let bytes else {
            return nil
        }
        return String(cString: bytes)
    }

    func toData(until: Int? = nil) -> Data {
        if let until {
            precondition(until <= ptr.pointee.length)
        }
        return Data(bytes: ptr.pointee.bytes, count: until ?? ptr.pointee.length)
    }

    func toHex() -> String {
        guard let bytes else {
            return ""
        }
        var hexString = ""
        for i in 0..<length {
            hexString += String(format: "%02x", bytes[i])
        }
        return hexString
    }
}
