// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_exported import PartoutCore
import PartoutNative

public enum PartoutRuntime {
    /// The library version.
    public static var version: String {
        guard let cVersion = partout_version() else {
            return "undefined"
        }
        return String(cString: cVersion)
    }
}
