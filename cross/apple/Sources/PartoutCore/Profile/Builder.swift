// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A failable builder.
public protocol BuilderType {
    associatedtype BuiltType

    func build() throws -> BuiltType
}

/// A type that can be built with a ``BuilderType``.
public protocol BuildableType {
    associatedtype B: BuilderType where B.BuiltType == Self

    func builder() -> B
}
