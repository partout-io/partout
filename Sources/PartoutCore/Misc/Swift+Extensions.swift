// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension Collection {
    public func first<T>(ofType type: T.Type) -> T? {
        first { $0 is T } as? T
    }

    public func unique() -> [Element] where Element: Equatable {
        reduce(into: []) {
            guard !$0.contains($1) else {
                return
            }
            $0.append($1)
        }
    }
}

extension Dictionary where Key == String, Value == Data {
    public func decode<T>(_ type: T.Type, forKey key: String) throws -> T? where T: Decodable {
        guard let data = self[key] else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public mutating func encode<T>(_ value: T, forKey key: String) throws where T: Encodable {
        self[key] = try JSONEncoder().encode(value)
    }
}

extension Array where Element == CChar {
    public var string: String {
        withUnsafeBytes {
            let buf = $0.bindMemory(to: CChar.self)
            return String(cString: buf.baseAddress!)
        }
    }
}
