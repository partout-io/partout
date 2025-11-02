// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public final class JSONEncoder {
    public enum OutputFormatting {
        case prettyPrinted
        case sortedKeys
    }

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public var outputFormatting: Set<OutputFormatting> = []

    public init() {
        fatalError()
    }

    public func encode<T>(_ value: T) throws -> Data where T: Encodable {
        fatalError()
    }
}

public final class JSONDecoder {
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {
    }

    public func decode<T>(_ value: T.Type, from data: Data) throws -> T where T: Decodable {
        fatalError()
    }
}

public struct JSONSerialization {
    public static func data(withJSONObject json: Any) throws -> Data {
        fatalError()
    }

    public static func jsonObject(with data: Data) throws -> Any {
        fatalError()
    }
}
