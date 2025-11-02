// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// MARK: Hex processing

// hex -> Data conversion code from: http://stackoverflow.com/questions/32231926/nsdata-from-hex-string
// Data -> hex conversion code from: http://stackoverflow.com/questions/39075043/how-to-convert-data-to-hex-string-in-swift

extension UnicodeScalar {

    /// The value of an hexadecimal digit.
    public var hexNibble: UInt8 {
        let value = self.value
        // 0-9
        if 48 <= value && value <= 57 {
            return UInt8(value - 48)
        }
        // A-F = 10-15
        else if 65 <= value && value <= 70 {
            return UInt8(value - 55)
        }
        // a-f = 10-15
        else if 97 <= value && value <= 102 {
            return UInt8(value - 87)
        }
        fatalError("\(self) not a legal hex nibble")
    }
}

extension Data {

    /// Creates data from a hex string.
    /// - Parameter hex: The hexadecimal representation of the data.
    public init(hex: String) {
        let scalars = hex.unicodeScalars
        var bytes = [UInt8](repeating: 0, count: (scalars.count + 1) >> 1)
        for (index, scalar) in scalars.enumerated() {
            var nibble = scalar.hexNibble
            if index & 1 == 0 {
                nibble <<= 4
            }
            bytes[index >> 1] |= nibble
        }
        self = Data(bytes)
    }

    /// - Returns: The hexadecimal representation of the data.
    public func toHex() -> String {
        map {
            String(format: "%02hhx", $0)
        }
        .joined()
    }
}

// MARK: - Zero

extension Data {

    /// Zeroes out the current data.
    public mutating func zero() {
        resetBytes(in: 0..<count)
    }

    /// Zeroes out part of the current data.
    /// - Parameters:
    ///   - from: The starting offset.
    ///   - to: The ending offset.
    public mutating func zero(from: Int, to: Int) {
        resetBytes(in: from..<to)
    }
}

// MARK: - Append/Parse

extension Data {

    /// Appends a 16-bit unsigned integer.
    /// - Parameter value: The value.
    public mutating func append(_ value: UInt16) {
        var localValue = value
        let buffer = withUnsafePointer(to: &localValue) {
            UnsafeBufferPointer(start: $0, count: 1)
        }
        append(buffer)
    }

    /// Appends a 32-bit unsigned integer.
    /// - Parameter value: The value.
    public mutating func append(_ value: UInt32) {
        var localValue = value
        let buffer = withUnsafePointer(to: &localValue) {
            UnsafeBufferPointer(start: $0, count: 1)
        }
        append(buffer)
    }

    /// Appends a 64-bit unsigned integer.
    /// - Parameter value: The value.
    public mutating func append(_ value: UInt64) {
        var localValue = value
        let buffer = withUnsafePointer(to: &localValue) {
            UnsafeBufferPointer(start: $0, count: 1)
        }
        append(buffer)
    }

    /// Appends a null-terminated string.
    /// - Parameter nullTerminatedString: The string terminated with `\0`.
    public mutating func append(nullTerminatedString: String) {
        guard let asciiData = nullTerminatedString.data(using: .ascii) else {
            fatalError("Unable to encode ASCII data")
        }
        append(asciiData)
        append(UInt8(0))
    }

    /// Parses a null-terminated string from a given offset.
    /// - Parameter from: The offset.
    /// - Returns: The parsed string or nil if no`\0` was found.
    public func nullTerminatedString(from: Int) -> String? {
        var nullOffset: Int?
        for i in from..<count {
            if self[i] == 0 {
                nullOffset = i
                break
            }
        }
        guard let to = nullOffset else {
            return nil
        }
        return String(data: subdata(in: from..<to), encoding: .ascii)
    }

    /// Parses a 16-bit unsigned integer from a given offset.
    /// - Parameter from: The offset.
    /// - Returns: The parsed value.
    public func UInt16Value(from: Int) -> UInt16 {
        var value: UInt16 = 0
        for i in 0..<2 {
            let byte = self[from + i]
            value |= (UInt16(byte) << UInt16(8 * i))
        }
        return value
    }

    /// Parses a 32-bit unsigned integer from a given offset.
    /// - Parameter from: The offset.
    /// - Returns: The parsed value.
    public func UInt32Value(from: Int) -> UInt32 {
        subdata(in: from..<(from + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
    }

    /// Parses a 16-bit integer in network byte-order.
    /// - Parameter from: The offset.
    /// - Returns: The parsed value.
    public func networkUInt16Value(from: Int) -> UInt16 {
        UInt16(bigEndian: subdata(in: from..<(from + 2)).withUnsafeBytes {
            $0.load(as: UInt16.self)
        })
    }

    /// Parses a 32-bit integer in network byte-order.
    /// - Parameter from: The offset.
    /// - Returns: The parsed value.
    public func networkUInt32Value(from: Int) -> UInt32 {
        UInt32(bigEndian: subdata(in: from..<(from + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self)
        })
    }
}

extension Data {
    public func subdata(offset: Int, count: Int) -> Data {
        subdata(in: offset..<(offset + count))
    }
}

// MARK: - Collections

extension Collection where Element == Data {

    /// The compound count of all the data in the collection.
    public var flatCount: Int {
        reduce(0) { $0 + $1.count }
    }
}

// MARK: - Byte pointers

extension UnsafeRawBufferPointer {

    /// The pointer to the internal data buffer.
    public var bytePointer: UnsafePointer<Element> {
        guard let address = bindMemory(to: Element.self).baseAddress else {
            fatalError("Cannot bind to self")
        }
        return address
    }
}

extension UnsafeMutableRawBufferPointer {

    /// The mutable pointer to the internal data buffer.
    public var bytePointer: UnsafeMutablePointer<Element> {
        guard let address = bindMemory(to: Element.self).baseAddress else {
            fatalError("Cannot bind to self")
        }
        return address
    }
}
