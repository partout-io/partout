// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Reads configuration values from the Info.plist of a `Bundle`.
public struct BundleConfiguration: @unchecked Sendable {
    private let cfg: [String: Any]

    public let versionNumber: String

    public let buildNumber: Int

    public let displayName: String

    public init?(_ bundle: Bundle, key: String) {
        guard let versionNumber = bundle.infoDictionary!["CFBundleShortVersionString"] as? String else {
            NSLog("Unable to parse version number")
            return nil
        }
        guard let buildNumberString = bundle.infoDictionary?[kCFBundleVersionKey as String] as? String,
              let buildNumber = Int(buildNumberString) else {
            NSLog("Unable to parse build number")
            return nil
        }
        guard let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String else {
            NSLog("Unable to parse display name")
            return nil
        }
        guard let cfg = bundle.infoDictionary?[key] as? [String: Any] else {
            NSLog("Key '\(key)' not found in bundle Info.plist")
            return nil
        }

        self.cfg = cfg
        self.versionNumber = versionNumber
        self.buildNumber = buildNumber
        self.displayName = displayName
    }

    public var versionString: String {
        "\(versionNumber) (\(buildNumber))"
    }

    public func value<V>(forKey key: String) -> V? {
        cfg[key] as? V
    }
}
