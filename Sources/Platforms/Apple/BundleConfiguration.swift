//
//  BundleConfiguration.swift
//  Partout
//
//  Created by Davide De Rosa on 3/29/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
