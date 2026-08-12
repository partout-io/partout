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

extension ConnectionModule {
    public var buildsConnection: Bool {
        true
    }

    // allow one active ConnectionModule at most
    public func checkCompatible(with otherModule: Module, activeIds: Set<UniqueID>) throws {
        precondition(otherModule.id != id)
        if !activeIds.contains(id) || !activeIds.contains(otherModule.id) {
            return
        }
        guard !otherModule.buildsConnection else {
            throw PartoutError(.incompatibleModules, [self, otherModule])
        }
    }
}

extension ModuleBuilder {
    public var buildsConnectionModule: Bool {
        BuiltType.self is ConnectionModule.Type
    }
}

extension ProfileType where GenericModuleType == Module {
    public var activeConnectionModule: ConnectionModule? {
        activeModules.first(ofType: ConnectionModule.self)
    }
}
