// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutOSPortable_C

public enum Partout {

    /// The unique identifier of the library.
    public static let identifier: String = {
        guard let str = String(cString: partout_identifier, encoding: .ascii) else {
            fatalError("NULL partout_identifier")
        }
        return str
    }()

    /// The library version.
    public static let version: String = {
        guard let str = String(cString: partout_version, encoding: .ascii) else {
            fatalError("NULL partout_version")
        }
        return str
    }()

    /// The computed version identifier.
    public static var versionIdentifier: String {
        "\(identifier) \(version)"
    }
}
