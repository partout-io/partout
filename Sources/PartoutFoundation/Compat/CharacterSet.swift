// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public struct CharacterSet: Sendable {
    public static let decimalDigits = CharacterSet(charactersIn: "0123456789")
    public static let newlines = CharacterSet(charactersIn: "\r\n")
    public static let urlHostAllowed = CharacterSet(charactersIn: "????????????") // FIXME
    public static let whitespaces = CharacterSet(charactersIn: " ")
    public static let whitespacesAndNewlines = CharacterSet(charactersIn: " \r\n")

    public init(charactersIn: String) {
        fatalError()
    }

    public func contains(_ ch: Unicode.Scalar) -> Bool {
        fatalError()
    }

    public var inverted: Self {
        fatalError()
    }

    public func union(_ other: Self) -> Self {
        fatalError()
    }
}
