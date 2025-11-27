// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

//public struct Data: Hashable, Codable {
//    public init() {
//    }
//}

public typealias Data = [UInt8]

extension Data {
    public var count: Int {
        get {
            fatalError()
        }
        set {
            fatalError()
        }
    }

    public init(_ data: Data) {
        fatalError()
    }

    public init(count: Int) {
        self.init(repeating: 0, count: count)
    }

    public init(capacity: Int) {
        fatalError()
    }

    public init(bytes: UnsafePointer<UInt8>, count: Int) {
        fatalError()
    }

    public init?(base64Encoded string: String) {
        fatalError()
    }

    public init(
        bytesNoCopy: UnsafeMutablePointer<UInt8>,
        count: Int,
        deallocator: @escaping () -> Void
    ) {
        fatalError()
    }

    public func subdata(in range: Range<Int>) -> Data {
        fatalError()
    }

    public func resetBytes(in range: Range<Int>) {
        fatalError()
    }

    public func append(_ data: Self) {
        fatalError()
    }

    public func append<T>(_ buf: UnsafeBufferPointer<T>) {
        fatalError()
    }

    public func append(_ uint8: UInt8) {
        fatalError()
    }

    public func base64EncodedString() -> String {
        fatalError()
    }
}

extension String {
    public enum Encoding {
        case ascii

        case utf8
    }

    public func data(using: String.Encoding) -> Data? {
        nil
    }
}
