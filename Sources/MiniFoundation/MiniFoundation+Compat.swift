// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if MINIF_COMPAT

internal import _MiniFoundationCore_C

// MARK: Types

public typealias CharacterSet = Compat.CharacterSet
public typealias Data = Compat.Data
public typealias Date = Compat.Date
public typealias FileManager = Compat.FileManager
public typealias IndexSet = [Int]
public typealias JSONDecoder = Compat.JSONDecoder
public typealias JSONEncoder = Compat.JSONEncoder
public typealias RegularExpression = Compat.RegularExpression
extension String {
    public typealias Encoding = Compat.StringEncoding
}
public typealias StringEncoding = Compat.StringEncoding
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

#endif
