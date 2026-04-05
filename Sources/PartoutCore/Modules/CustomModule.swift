// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A type-erased ``Module`` for encoding external implementations.
public struct CustomModule: Module, Hashable, Codable {
    public static let moduleType = ModuleType("Custom")

    public let innerType: ModuleType

    public let json: JSON

    public init(_ module: Module & Encodable) throws {
        innerType = module.moduleType
        json = try JSON(encodable: module)
    }
}
