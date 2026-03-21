// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public struct IRModel {
    public enum Kind {
        case `struct`
        case `enum`(String)
    }
    public let name: String
    public let kind: Kind
    public let properties: [IRProperty]
    public let parents: [IRScope]
}

public struct IRAlias {
    public let name: String
    public let kind: IRType
    public let parents: [IRScope]
}

public struct IRProperty {
    public let name: String
    public let serializedName: String?
    public let type: IRType
    public let scope: [IRScope]
    public let associatedProperties: [IRProperty]

    public var effectiveSerializedName: String {
        serializedName ?? name
    }
}

public indirect enum IRType {
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

public enum IRScope {
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

public struct IRContext {
    public var models: [IRModel] = []
    public var aliases: [IRAlias] = []
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
    func encodeDocument(ctx: IRContext) -> String?
    func encode(_ model: IRModel, ctx: IRContext) -> String
    func encode(_ alias: IRAlias, ctx: IRContext) -> String
    func encode(_ type: IRType, ctx: IRContext) -> String
}

extension IREncoder {
    func encodePreamble() -> String? { nil }
    func encodeDocument(ctx: IRContext) -> String? { nil }
}

// MARK: - Extensions

public protocol IRWithParents {
    var typeName: String { get }
    var parents: [IRScope] { get }
}

extension IRWithParents {
    var fqType: [String] {
        parents.map(\.stringValue) + [typeName]
    }

    public var fqTypeName: String {
        fqType.joined(separator: ".")
    }
}

extension IRModel: IRWithParents {
    public var typeName: String {
        name
    }
}

extension IRAlias: IRWithParents {
    public var typeName: String {
        name
    }
}

// MARK: - Descriptions

extension IRModel.Kind: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .struct:
            "struct"
        case .enum(let rawType):
            "enum(\(rawType))"
        }
    }
}

extension IRProperty: CustomDebugStringConvertible {
    public var debugDescription: String {
        let serializedSuffix = serializedName.map { " => \($0)" } ?? ""
        return "\(name)\(serializedSuffix): \(type)"
    }
}
