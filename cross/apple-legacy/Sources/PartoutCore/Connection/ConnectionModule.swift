// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Special ``Module`` able to establish a ``Connection``.
public protocol ConnectionModule: Module {

    /// Creates a new connection.
    /// - Parameters:
    ///   - impl: The internal implementation of the module. Modules should provide their specifics here.
    ///   - parameters: The ``ConnectionParameters`` to create the connection with.
    /// - Returns: A new connection.
    /// - Throws: If the implementation is missing or incorrect.
    func newConnection(with impl: ModuleImplementation?, parameters: ConnectionParameters) throws -> Connection
}
