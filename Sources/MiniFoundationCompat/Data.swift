// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

// FIXME: #228, Implement with pp_zd maybe, use @inline, beware of performance

extension Compat {
    public struct Data: Hashable, Codable, Sendable {
        private var backend: [UInt8]

        public init(capacity: Int = 0) {
            backend = []
            backend.reserveCapacity(capacity)
        }

        public init(_ data: Self) {
            backend = data.backend
        }

        public init(_ bytes: [UInt8]) {
            backend = bytes
        }

        public init(repeating: UInt8 = 0, count: Int) {
            backend = Array(repeating: repeating, count: count)
        }

        public init(bytes: UnsafePointer<UInt8>, count: Int) {
            backend = Array(UnsafeBufferPointer(start: bytes, count: count))
        }

        public init(_ slice: ArraySlice<UInt8>) {
            backend = Array(slice)
        }

        public subscript(index: Int) -> UInt8 {
            get {
                backend[index]
            }
            set {
                backend[index] = newValue
            }
        }

        public var bytes: [UInt8] {
            backend
        }

        public var count: Int {
            backend.count
        }

        public var isEmpty: Bool {
            backend.isEmpty
        }

        public var first: UInt8? {
            backend.first
        }

        public func map<T>(_ transform: (UInt8) throws -> T) rethrows -> [T] {
            try backend.map(transform)
        }

        public func subdata(in range: Range<Int>) -> Self {
            Data(backend[range.lowerBound..<range.upperBound])
        }

        public func subdata(offset: Int, count: Int) -> Self {
            Data(backend[offset..<offset + count])
        }

        public func enumerated() -> EnumeratedSequence<[UInt8]> {
            backend.enumerated()
        }

        public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            try backend.withUnsafeBytes(body)
        }

        public mutating func reserveCapacity(_ capacity: Int) {
            backend.reserveCapacity(capacity)
        }

        public mutating func withUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
            try backend.withUnsafeMutableBytes(body)
        }

        public mutating func resetBytes(in range: Range<Int>) {
            guard !range.isEmpty else { return }
            precondition(range.lowerBound >= 0 && range.upperBound <= backend.count)
            backend.withUnsafeMutableBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.advanced(by: range.lowerBound) else {
                    return
                }
                memset(ptr, 0, range.count)
            }
        }

        public mutating func append(_ data: Self) {
            backend += data.backend
        }

        public mutating func append<T>(_ buf: UnsafeBufferPointer<T>) {
            guard let baseAddress = buf.baseAddress else { return }
            let byteCount = buf.count * MemoryLayout<T>.stride
            let bytePtr = UnsafeRawBufferPointer(start: baseAddress, count: byteCount)
            backend.append(contentsOf: bytePtr)
        }

        public mutating func append(_ uint8: UInt8) {
            backend += [uint8]
        }

        public mutating func shrink(to newCount: Int) {
            precondition(newCount <= count, "Shrink must be to a smaller size")
            guard newCount < count else { return }
            backend.removeLast(count - newCount)
        }

        public func write(toFile path: String) throws {
            let file = FileBuffer(bytes: bytes)
            try file.write(toFile: path)
        }

        // MARK: Codable

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let base64 = try container.decode(String.self)
            guard let data = Data(base64Encoded: base64) else {
                throw MiniFoundationError.decoding
            }
            self = data
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(backend.base64EncodedString())
        }
    }
}

extension Compat.Data {
    public init?(base64Encoded string: String) {
        var count = 0
        let bytes = string.withCString { str in
            minif_base64_decode(str, string.count, &count)
        }
        guard let bytes else { return nil }
        backend = Array(UnsafeBufferPointer(start: bytes, count: count))
        bytes.deallocate()
    }

    public func base64EncodedString() -> String {
        backend.base64EncodedString()
    }
}

extension Compat.Data {
    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int) {
        // FIXME: #228, DO NOT COPY BYTES
        self.init(bytes: bytesNoCopy, count: count)
    }

    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int, customDeallocator: @escaping () -> Void) {
        // FIXME: #228, DO NOT COPY BYTES
        self.init(bytes: bytesNoCopy, count: count)
    }
}

extension Array where Element == UInt8 {
    public init(_ data: Compat.Data) {
        self = data.bytes
    }

    fileprivate func base64EncodedString() -> String {
        var encodedCount = 0
        guard let str = minif_base64_encode(self, count, &encodedCount) else {
            assertionFailure()
            return ""
        }
        let encoded = String(cString: str)
        assert(encoded.count == encodedCount)
        str.deallocate()
        return encoded
    }
}

extension Array where Element == Compat.Data {
    public func joined() -> Compat.Data {
        reduce(into: Compat.Data()) {
            $0.append($1)
        }
    }
}
