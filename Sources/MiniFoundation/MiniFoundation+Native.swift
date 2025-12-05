// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINI_FOUNDATION_COMPAT

@_exported import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
@_exported import MiniFoundationNative
#endif

// MARK: Types

public typealias RegularExpression = NativeRegularExpression

// MARK: - Extensions

extension MiniFoundation {
    public static func operatingSystemVersion() -> MiniOSVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MiniOSVersion(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
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

#endif
