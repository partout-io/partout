// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

struct IRModel {
    enum Kind: String {
        case `struct`
        case `enum`
    }
    let name: String
    let kind: Kind
    let properties: [IRProperty]
    let parents: [IRScope]
}

struct IRAlias {
    let name: String
    let kind: IRType
    let parents: [IRScope]
}

struct IRProperty {
    let name: String
    let type: IRType
    let scope: [IRScope]
}

indirect enum IRType {
    case string
    case int
    case double
    case bool
    case uuid
    case url
    case data
    case date
    case json
    case optional(IRType)
    case array(IRType)
    case dictionary(key: IRType, value: IRType)
    case set(IRType)
    case enumType(String)
    case unresolved(String)
    case custom(search: (IRContext) -> String?, fallback: String)
}

enum IRScope {
    case `extension`(String)
    case `struct`(String)
    case `enum`(String)
    var stringValue: String {
        switch self {
        case .extension(let s):
            return s
        case .struct(let s):
            return s
        case .enum(let s):
            return s
        }
    }
}

// MARK: - Encoder

struct IRContext {
    var models: [IRModel] = []
    var aliases: [IRAlias] = []
    func merging(_ other: IRContext) -> IRContext {
        var copy = self
        copy.models += other.models
        copy.aliases += other.aliases
        return copy
    }
    mutating func merge(_ other: IRContext) {
        self = merging(other)
    }
}

protocol IREncoder {
    func encodePreamble() -> String?
    func encode(_ model: IRModel, ctx: IRContext) -> String
    func encode(_ alias: IRAlias, ctx: IRContext) -> String
    func encode(_ type: IRType, ctx: IRContext) -> String
}

extension IREncoder {
    func encodePreamble() -> String? { nil }
}

// MARK: - Extensions

protocol IRWithParents {
    var typeName: String { get }
    var parents: [IRScope] { get }
}

extension IRWithParents {
    var fqType: [String] {
        parents.map(\.stringValue) + [typeName]
    }

    var fqTypeName: String {
        fqType.joined(separator: ".")
    }
}

extension IRModel: IRWithParents {
    var typeName: String {
        name
    }
}

extension IRAlias: IRWithParents {
    var typeName: String {
        name
    }
}

// MARK: - Descriptions

extension IRModel.Kind: CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue
    }
}

extension IRProperty: CustomDebugStringConvertible {
    var debugDescription: String {
        "\(name): \(type)"
    }
}
