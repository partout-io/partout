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

#endif
