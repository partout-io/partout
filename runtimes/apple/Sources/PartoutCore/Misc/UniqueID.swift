// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

/// Alias for a unique identifier.
public typealias UniqueID = UUID

/// Any entity that can be identified with an ``UniqueID``.
public protocol UniquelyIdentifiable {
    var id: UniqueID { get }
}

public protocol MutableUniquelyIdentifiable: UniquelyIdentifiable {
    var id: UniqueID { get set }
}
