// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

/// A type that can be randomly initialized with the default initializer.
public protocol RandomlyInitialized: Hashable, Sendable {
    init()
}
