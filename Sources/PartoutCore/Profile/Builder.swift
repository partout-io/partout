// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// A failable builder.
public protocol BuilderType {
    associatedtype BuiltType

    func tryBuild() throws -> BuiltType
}

/// A type that can be built with a ``BuilderType``.
public protocol BuildableType {
    associatedtype B: BuilderType where B.BuiltType == Self

    func builder() -> B
}
