// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINIF_MONOLITH
#if canImport(MiniFoundationNative)
@_exported import MiniFoundationNative
#elseif canImport(MiniFoundationCompat)
@_exported import MiniFoundationCompat
#endif
#endif

extension UUID: RandomlyInitialized {}

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
