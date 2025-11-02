// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore_C

/// Wrapper of binary data that zeroes out itself on deallocation.
public final class CZeroingData {
    public let ptr: UnsafeMutablePointer<pp_zd>

    public init(ptr: UnsafeMutablePointer<pp_zd>) {
        self.ptr = ptr
    }

    public init(count: Int) {
        ptr = pp_zd_create(count)
    }

    public init(bytes: UnsafePointer<UInt8>, count: Int) {
        ptr = pp_zd_create_from_data(bytes, count)
    }

    public init(uInt8: UInt8) {
        var value = uInt8
        ptr = pp_zd_create_from_data(&value, 1)
    }

    public init(uInt16: UInt16) {
        var value = uInt16
        ptr = withUnsafeBytes(of: &value) {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return pp_zd_create_from_data(bytes, 2)
        }
    }

    public init(data: Data) {
        ptr = data.withUnsafeBytes {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return pp_zd_create_from_data(bytes, data.count)
        }
    }

    public init(data: Data, offset: Int, count: Int) {
        ptr = data.withUnsafeBytes {
            guard let bytes = $0.bindMemory(to: UInt8.self).baseAddress else {
                fatalError("Could not bind to memory")
            }
            return pp_zd_create_from_data_range(bytes, offset, count)
        }
    }

    public init(string: String, nullTerminated: Bool) {
        ptr = string.withCString {
            pp_zd_create_from_string($0, nullTerminated)
        }
    }

    public init(hex: String) {
        ptr = hex.withCString {
            pp_zd_create_from_hex($0) ?? pp_zd_create(0)
        }
    }

    deinit {
        pp_zd_free(ptr)
    }
}

// MARK: Properties

extension CZeroingData {
    public var bytes: UnsafePointer<UInt8>! {
        pp_zd_bytes(ptr)
    }

    public var mutableBytes: UnsafeMutablePointer<UInt8>! {
        pp_zd_mutable_bytes(ptr)
    }

    public var count: Int {
        pp_zd_length(ptr)
    }
}

extension CZeroingData: Equatable {
    public static func == (lhs: CZeroingData, rhs: CZeroingData) -> Bool {
        pp_zd_equals(lhs.ptr, rhs.ptr)
    }

    public func isEqual(to data: Data) -> Bool {
        let length = data.count
        return data.withUnsafeBytes { dataPtr in
            pp_zd_equals_to_data(ptr, dataPtr.bytePointer, length)
        }
    }
}

// MARK: Copy

extension CZeroingData {
    public func copy() -> CZeroingData {
        CZeroingData(ptr: pp_zd_make_copy(ptr))
    }

    public func withOffset(_ offset: Int, count: Int) -> CZeroingData {
        guard let slice = pp_zd_make_slice(ptr, offset, count) else {
            return CZeroingData(count: 0)
        }
        return CZeroingData(ptr: slice)
    }

    public func appending(_ other: CZeroingData) -> CZeroingData {
        let copy = pp_zd_make_copy(ptr)
        pp_zd_append(copy, other.ptr)
        return CZeroingData(ptr: copy)
    }
}

// MARK: Side effect

extension CZeroingData {
    public func zero() {
        pp_zd_zero(ptr)
    }

    public func resize(toSize size: Int) {
        pp_zd_resize(ptr, size)
    }

    public func remove(untilOffset offset: Int) {
        pp_zd_remove_until(ptr, offset)
    }

    public func append(_ other: CZeroingData) {
        pp_zd_append(ptr, other.ptr)
    }
}

// MARK: Accessors

extension CZeroingData {
    public func networkUInt16Value(fromOffset offset: Int) -> UInt16 {
        pp_endian_ntohs(pp_zd_uint16(ptr, offset))
    }

    public func nullTerminatedString(fromOffset offset: Int) -> String? {
        var nullOffset: Int?
        var i = offset
        while i < count {
            if bytes[i] == 0 {
                nullOffset = i
                break
            }
            i += 1
        }
        guard let nullOffset else {
            return nil
        }
        let stringLength = nullOffset - offset
        let data = Data(bytes: bytes, count: stringLength)
        return String(data: data, encoding: .utf8)
    }

    public func toData(until: Int? = nil) -> Data {
        if let until {
            precondition(until <= ptr.pointee.length)
        }
        return Data(bytes: ptr.pointee.bytes, count: until ?? ptr.pointee.length)
    }

    public func toHex() -> String {
        guard let bytes else {
            return ""
        }
        var hexString = ""
        for i in 0..<count {
            hexString += String(format: "%02x", bytes[i])
        }
        return hexString
    }
}

// MARK: Logging

extension SecureData {
    public var czData: CZeroingData {
        CZeroingData(data: toData())
    }
}

extension CZeroingData: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? "[\(count) bytes, \(toHex())]" : "[\(count) bytes]"
    }
}
