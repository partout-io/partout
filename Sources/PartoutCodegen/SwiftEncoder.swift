// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

// This is only a showcase to get the hang of the
// encoding process. It may break from time to time.
final class SwiftEncoder: IREncoder {
    func encode(_ model: IRModel, ctx: IRContext) -> String {
        var desc: [String] = []
        let fqTypeName = model.fqTypeName.normalizedTypeName
        switch model.kind {
        case .enum:
            desc.append("enum \(fqTypeName) {")
            model.properties.forEach {
                desc.append("    case \($0.name)")
            }
        case .struct:
            desc.append("struct \(fqTypeName) {")
            model.properties.forEach {
                let typeName = encode($0.type, ctx: ctx)
                desc.append("    let \($0.name): \(typeName.normalizedTypeName)")
            }
        }
        desc.append("}")
        return desc.joined(separator: "\n")
    }

    func encode(_ alias: IRAlias, ctx: IRContext) -> String {
        "typealias \(alias.fqTypeName.normalizedTypeName) = \(encode(alias.kind, ctx: ctx))"
    }

    func encode(_ type: IRType, ctx: IRContext) -> String {
        switch type {
        case .string:
            "String"
        case .int:
            "Int"
        case .double:
            "Double"
        case .bool:
            "Bool"
        case .uuid:
            "UUID"
        case .url:
            "URL"
        case .data:
            "Data"
        case .date:
            "Date"
        case .json:
            "JSON"
        case .optional(let wrapped):
            "\(encode(wrapped, ctx: ctx))?"
        case .array(let element):
            "[\(encode(element, ctx: ctx))]"
        case .dictionary(let key, let value):
            "[\(encode(key, ctx: ctx)): \(encode(value, ctx: ctx))]"
        case .set(let element):
            "Set<\(encode(element, ctx: ctx))>"
        case .enumType(let name):
            name.normalizedTypeName
        case .unresolved(let name):
            name.normalizedTypeName
        case .custom(let search, let fallback):
            (search(ctx) ?? fallback).normalizedTypeName
        }
    }
}

private extension String {
    var normalizedTypeName: String {
        switch self {
        case "Profile.ID": "String"
        default: replacingOccurrences(of: ".", with: "_")
        }
    }
}
