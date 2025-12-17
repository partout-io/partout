// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINI_FOUNDATION_COMPAT

// MARK: Types

public typealias RegularExpression = NativeRegularExpression
public typealias StringEncoding = String.Encoding

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

#endif
