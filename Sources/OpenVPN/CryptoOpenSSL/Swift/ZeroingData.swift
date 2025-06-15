//
//  ZeroingData.swift
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

public final class ZeroingData {
    private(set) var ptr: UnsafeMutablePointer<zeroing_data_t>?

    private init(ptr: UnsafeMutablePointer<zeroing_data_t>) {
        self.ptr = ptr
    }

    public init(length: Int = 0) {
        self.ptr = zd_create(length)
    }

    public init(bytes: UnsafePointer<UInt8>?, length: Int) {
        self.ptr = zd_create_from_data(bytes, length)
    }

    public init(uInt8: UInt8) {
        var value = uInt8
        self.ptr = zd_create_from_data(&value, 1)
    }

    public init(uInt16: UInt16) {
        var value = uInt16
        let ptr = withUnsafeBytes(of: &value) { $0.bindMemory(to: UInt8.self).baseAddress }
        self.ptr = zd_create_from_data(ptr, 2)
    }

    public init(data: Data) {
        data.withUnsafeBytes {
            self.ptr = zd_create_from_data($0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }

    public init(data: Data, offset: Int, length: Int) {
        data.withUnsafeBytes {
            self.ptr = zd_create_from_data_range($0.bindMemory(to: UInt8.self).baseAddress, offset, length)
        }
    }

    public init(string: String, nullTerminated: Bool) {
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

extension ZeroingData {
    public var bytes: UnsafePointer<UInt8>? {
        zd_bytes(ptr)
    }

    public var mutableBytes: UnsafeMutablePointer<UInt8>? {
        zd_mutable_bytes(ptr)
    }

    public var length: Int {
        Int(zd_length(ptr))
    }
}

extension ZeroingData: Equatable {
    public static func == (lhs: ZeroingData, rhs: ZeroingData) -> Bool {
        zd_equals(lhs.ptr, rhs.ptr)
    }
}

// MARK: Copy

extension ZeroingData {
    public func copy() -> ZeroingData {
        ZeroingData(ptr: zd_make_copy(self.ptr))
    }

    public func withOffset(_ offset: Int, length: Int) -> ZeroingData {
        ZeroingData(ptr: zd_make_slice(ptr, offset, length))
    }

    public func appending(_ other: ZeroingData) -> ZeroingData {
        guard let copy = zd_make_copy(ptr) else {
            return ZeroingData()
        }
        zd_append(copy, other.ptr)
        return ZeroingData(ptr: copy)
    }
}

// MARK: Side effect

extension ZeroingData {
    public func zero() {
        zd_zero(ptr)
    }

    public func truncate(toSize size: Int) {
        zd_truncate(ptr, size)
    }

    public func remove(untilOffset offset: Int) {
        zd_remove_until(ptr, offset)
    }

    public func append(_ other: ZeroingData) {
        zd_append(ptr, other.ptr)
    }
}

// MARK: Accessors

extension ZeroingData {
    public func networkUInt16Value(fromOffset offset: Int) -> UInt16 {
        CFSwapInt16BigToHost(zd_uint16(ptr, offset))
    }

    public func nullTerminatedString(fromOffset offset: Int) -> String? {
        precondition(offset <= length)
        guard let bytes else {
            return nil
        }
        return String(cString: bytes)
    }

    public func toData() -> Data {
        guard let ptr else {
            return Data()
        }
        return Data(bytes: ptr.pointee.bytes, count: ptr.pointee.length)
    }
}
