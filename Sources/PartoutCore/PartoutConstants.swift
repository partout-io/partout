// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
@_exported import MiniFoundation
#endif
import PartoutABI_C

public enum PartoutConstants {

    /// The unique identifier of the library.
    public static let identifier: String = {
        guard let str = String(cString: PARTOUT_IDENTIFIER, encoding: .ascii) else {
            fatalError("NULL partout_identifier")
        }
        return str
    }()

    /// The library version.
    public static let version: String = {
        guard let str = String(cString: PARTOUT_VERSION, encoding: .ascii) else {
            fatalError("NULL partout_version")
        }
        return str
    }()

    /// The computed version identifier.
    public static var versionIdentifier: String {
        "\(identifier) \(version)"
    }
}
