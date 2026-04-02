// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public enum PartoutConstants {
    /// The unique identifier of the library.
    public static let identifier = "io.partout"

    /// The library version.
    public static let version = "0.122.0"

    /// The computed version identifier.
    public static let versionIdentifier: String = "\(identifier) \(version)"

    /// The C flavor of ``versionIdentifier``.
    public static var cVersionIdentifier: UnsafePointer<CChar> {
        // This is safe because the subject is statically allocated.
        versionIdentifier.withCString(\.self)
    }
}
