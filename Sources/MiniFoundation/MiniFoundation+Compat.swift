// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if MINI_FOUNDATION_COMPAT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
@_exported import MiniFoundationCompat
import MiniFoundationCore
#endif

// MARK: Types

public typealias CharacterSet = Compat.CharacterSet
public typealias Data = Compat.Data
public typealias Date = Compat.Date
public typealias FileManager = Compat.FileManager
public typealias IndexSet = [Int]
public typealias RegularExpression = Compat.RegularExpression
public typealias TimeInterval = Compat.TimeInterval
public typealias URL = Compat.URL
public typealias UUID = Compat.UUID

// MARK: - Extensions

extension MiniFoundation {
    public static func operatingSystemVersion() -> MiniOSVersion {
        var major: Int32 = 0
        var minor: Int32 = 0
        var patch: Int32 = 0
        minif_os_get_version(&major, &minor, &patch)
        return MiniOSVersion(
            major: Int(major),
            minor: Int(minor),
            patch: Int(patch)
        )
    }
}

extension Dictionary where Key == String, Value == Compat.Data {
    public func decode<T>(_ type: T.Type, forKey key: String) throws -> T? where T: Decodable {
        // FIXME: #228, Implement native/compat agnostic with TextDecoder
        nil
    }

    public mutating func encode<T>(_ value: T, forKey key: String) throws where T: Encodable {
        // FIXME: #228, Implement native/compat agnostic with TextEncoder
    }
}

#endif
