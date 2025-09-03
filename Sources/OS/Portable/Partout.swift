// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public enum Partout {
    /// The unique identifier of the library.
    public static let identifier = "com.algoritmico.Partout"

    /// The library version.
    public static let version = "0.99.x"

    /// The computed version identifier.
    public static var versionIdentifier: String {
        "\(identifier) \(version)"
    }
}

