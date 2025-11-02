// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Alias for a unique identifier.
public typealias UniqueID = UUID

/// Any entity that can be identified with an ``UniqueID``.
public protocol UniquelyIdentifiable {
    var id: UniqueID { get }
}

public protocol MutableUniquelyIdentifiable: UniquelyIdentifiable {
    var id: UniqueID { get set }
}
