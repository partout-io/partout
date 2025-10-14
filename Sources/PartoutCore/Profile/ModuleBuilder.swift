// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Builds a ``Module`` via an internal builder.
///
/// A module builder comes with a builder able to create its ``Module`` counterpart.
/// - Seealso: Have a look at ``DNSModule/Builder`` inside ``DNSModule`` for an example.
public protocol ModuleBuilder: Sendable, UniquelyIdentifiable, BuilderType where BuiltType: Module {
    static func empty() -> Self
}

extension ModuleBuilder {
    public static var moduleHandler: ModuleHandler {
        BuiltType.moduleHandler
    }

    public var moduleHandler: ModuleHandler {
        Self.moduleHandler
    }

    public var buildsConnectionModule: Bool {
        BuiltType.self is ConnectionModule.Type
    }
}
