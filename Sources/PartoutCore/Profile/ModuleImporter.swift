// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Imports a ``Module`` from a text content.
public protocol ModuleImporter: Sendable {
    func module(fromContents contents: String, object: Any?) throws -> Module
}

extension ModuleImporter {
    public func module(fromContents contents: String) throws -> Module {
        try module(fromContents: contents, object: nil)
    }

    public func module(fromPath path: String, object: Any? = nil) throws -> Module {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return try module(fromContents: contents, object: object)
    }
}
