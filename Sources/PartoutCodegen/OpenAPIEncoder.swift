// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation

public final class OpenAPIEncoder {
    public init() {}
}

extension OpenAPIEncoder {
    func encodeDocument(ctx: IRContext) -> String? {
        serialize(mergedSchemaDocument(ctx: ctx))
    }

    func encode(_ model: IRModel, ctx: IRContext) -> String {
        serialize(schemaDocument(for: .model(model), ctx: ctx))
    }

    func encode(_ alias: IRAlias, ctx: IRContext) -> String {
        serialize(schemaDocument(for: .alias(alias), ctx: ctx))
    }

    func encode(_ type: IRType, ctx: IRContext) -> String {
        serialize(schema(for: type, root: nil, ctx: ctx, referenceStyle: .file))
    }
}

private extension OpenAPIEncoder {
    enum ReferenceStyle {
        case file
        case components
    }

    enum Definition {
        case model(IRModel)
        case alias(IRAlias)

        var fqTypeName: String {
            switch self {
            case .model(let model):
                model.fqTypeName
            case .alias(let alias):
                alias.fqTypeName
            }
        }
    }

    func schemaDocument(for root: Definition, ctx: IRContext) -> [String: Any] {
        var schema = schema(for: root, root: root.fqTypeName, ctx: ctx, referenceStyle: .file)
        schema["title"] = root.fqTypeName
        return schema
    }

    func mergedSchemaDocument(ctx: IRContext) -> [String: Any] {
        var schemas: [String: Any] = [:]
        for model in ctx.models {
            schemas.merge(
                schemaEntries(for: model, ctx: ctx, referenceStyle: .components),
                uniquingKeysWith: { _, new in new }
            )
        }
        for alias in ctx.aliases {
            schemas[alias.fqTypeName] = schema(
                for: .alias(alias),
                root: alias.fqTypeName,
                ctx: ctx,
                referenceStyle: .components
            )
        }
        return [
            "openapi": "3.1.0",
            "info": [
                "title": "codegen",
                "version": "1.0.0"
            ],
            "paths": [:],
            "components": [
                "schemas": schemas
            ]
        ]
    }

    func schema(
        for definition: Definition,
        root: String,
        ctx: IRContext,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        switch definition {
        case .model(let model):
            switch model.kind {
            case .enum(let rawType):
                if isDiscriminatedObjectEnum(model) {
                    return discriminatedBaseSchema(for: model, referenceStyle: referenceStyle)
                }
                if rawType == "Int" {
                    return [
                        "type": "integer",
                        "enum": Array(model.properties.indices),
                        "x-enum-varnames": model.properties.map(\.name)
                    ]
                }
                return [
                    "type": "string",
                    "enum": model.properties.map(\.name)
                ]
            case .struct:
                var properties: [String: Any] = [:]
                var required: [String] = []
                for property in model.properties {
                    let serializedName = property.effectiveSerializedName
                    properties[serializedName] = schema(
                        for: property.type,
                        root: root,
                        ctx: ctx,
                        referenceStyle: referenceStyle
                    )
                    if !isOptional(property.type) {
                        required.append(serializedName)
                    }
                }
                var objectSchema: [String: Any] = [
                    "type": "object",
                    "properties": properties,
                    "additionalProperties": false
                ]
                if !required.isEmpty {
                    objectSchema["required"] = required
                }
                return objectSchema
            }
        case .alias(let alias):
            return schema(for: alias.kind, root: root, ctx: ctx, referenceStyle: referenceStyle)
        }
    }

    func schema(
        for type: IRType,
        root: String?,
        ctx: IRContext,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        switch type {
        case .string:
            ["type": "string"]
        case .int:
            ["type": "integer"]
        case .double:
            ["type": "number"]
        case .bool:
            ["type": "boolean"]
        case .uuid:
            [
                "type": "string",
                "format": "uuid"
            ]
        case .url:
            [
                "type": "string",
                "format": "uri"
            ]
        case .data:
            [
                "type": "string",
                "format": "byte"
            ]
        case .date:
            [
                "type": "string",
                "format": "date-time"
            ]
        case .json:
            [:]
        case .optional(let wrapped):
            schema(for: wrapped, root: root, ctx: ctx, referenceStyle: referenceStyle)
        case .array(let element):
            [
                "type": "array",
                "items": schema(for: element, root: root, ctx: ctx, referenceStyle: referenceStyle)
            ]
        case .dictionary(_, let value):
            [
                "type": "object",
                "additionalProperties": schema(for: value, root: root, ctx: ctx, referenceStyle: referenceStyle)
            ]
        case .set(let element):
            [
                "type": "array",
                "items": schema(for: element, root: root, ctx: ctx, referenceStyle: referenceStyle),
                "uniqueItems": true
            ]
        case .enumType(let name), .unresolved(let name):
            referenceSchema(for: name, root: root, ctx: ctx, referenceStyle: referenceStyle)
        case .custom(let search, let fallback):
            referenceSchema(for: search(ctx) ?? fallback, root: root, ctx: ctx, referenceStyle: referenceStyle)
        }
    }

    func referenceSchema(
        for name: String,
        root: String?,
        ctx: IRContext,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        guard let definition = resolveDefinition(named: name, ctx: ctx) else {
            return ["title": name]
        }
        let fqTypeName = definition.fqTypeName
        if fqTypeName == root {
            return ["$ref": "#"]
        }
        switch referenceStyle {
        case .file:
            return ["$ref": "\(fqTypeName).yaml"]
        case .components:
            return ["$ref": "#/components/schemas/\(fqTypeName)"]
        }
    }

    func resolveDefinition(named name: String, ctx: IRContext) -> Definition? {
        if let alias = ctx.aliases.first(where: {
            $0.fqTypeName == name || $0.name == name
        }) {
            return .alias(alias)
        }
        if let model = ctx.models.first(where: {
            $0.fqTypeName == name || $0.name == name
        }) {
            return .model(model)
        }
        return nil
    }

    func isOptional(_ type: IRType) -> Bool {
        if case .optional = type {
            return true
        }
        return false
    }

    func schemaEntries(
        for model: IRModel,
        ctx: IRContext,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        var schemas: [String: Any] = [
            model.fqTypeName: schema(
                for: .model(model),
                root: model.fqTypeName,
                ctx: ctx,
                referenceStyle: referenceStyle
            )
        ]
        guard isDiscriminatedObjectEnum(model) else {
            return schemas
        }
        for enumCase in model.properties {
            schemas["\(model.fqTypeName).\(enumCase.name)"] = discriminatedCaseSchema(
                for: enumCase,
                in: model,
                ctx: ctx,
                referenceStyle: referenceStyle
            )
        }
        return schemas
    }

    func isDiscriminatedObjectEnum(_ model: IRModel) -> Bool {
        guard case .enum(let rawType) = model.kind else {
            return false
        }
        guard rawType == "String" else {
            return false
        }
        return model.properties.contains {
            !$0.associatedProperties.isEmpty
        }
    }

    func discriminatedBaseSchema(
        for model: IRModel,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        let mapping: [String: String] = Dictionary(uniqueKeysWithValues: model.properties.map { enumCase in
            (
                enumCase.name,
                refSchema(
                    for: "\(model.fqTypeName).\(enumCase.name)",
                    referenceStyle: referenceStyle
                )["$ref"] as! String
            )
        })
        return [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string"
                ]
            ],
            "required": ["type"],
            "discriminator": [
                "propertyName": "type",
                "mapping": mapping
            ]
        ]
    }

    func discriminatedCaseSchema(
        for enumCase: IRProperty,
        in model: IRModel,
        ctx: IRContext,
        referenceStyle: ReferenceStyle
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "type": [
                "type": "string",
                "const": enumCase.name
            ]
        ]
        var required = ["type"]
        for associatedProperty in enumCase.associatedProperties {
            let serializedName = associatedProperty.effectiveSerializedName
            properties[serializedName] = schema(
                for: associatedProperty.type,
                root: model.fqTypeName,
                ctx: ctx,
                referenceStyle: referenceStyle
            )
            if !isOptional(associatedProperty.type) {
                required.append(serializedName)
            }
        }
        return [
            "allOf": [
                refSchema(for: model.fqTypeName, referenceStyle: referenceStyle)
            ],
            "type": "object",
            "properties": properties,
            "additionalProperties": false,
            "required": required
        ]
    }

    func refSchema(for fqTypeName: String, referenceStyle: ReferenceStyle) -> [String: Any] {
        switch referenceStyle {
        case .file:
            return ["$ref": "\(fqTypeName).yaml"]
        case .components:
            return ["$ref": "#/components/schemas/\(fqTypeName)"]
        }
    }

    func serialize(_ object: Any) -> String {
        yaml(from: object)
    }

    func yaml(from value: Any, indent: Int = 0) -> String {
        switch value {
        case let dictionary as [String: Any]:
            return yamlObject(dictionary, indent: indent)
        case let array as [Any]:
            return yamlArray(array, indent: indent)
        case let string as String:
            return yamlString(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        default:
            return "null"
        }
    }

    func yamlObject(_ dictionary: [String: Any], indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        let sorted = dictionary.keys.sorted()
        return sorted.map { key in
            let value = dictionary[key]!
            if isScalar(value) {
                return "\(prefix)\(yamlKey(key)): \(yaml(from: value, indent: indent + 2))"
            }
            let nested = yaml(from: value, indent: indent + 2)
            if nested.isEmpty {
                return "\(prefix)\(yamlKey(key)): {}"
            }
            return "\(prefix)\(yamlKey(key)):\n\(nested)"
        }.joined(separator: "\n")
    }

    func yamlArray(_ array: [Any], indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        return array.map { item in
            if isScalar(item) {
                return "\(prefix)- \(yaml(from: item, indent: indent + 2))"
            }
            let nested = yaml(from: item, indent: indent + 2)
            let lines = nested.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = lines.first else {
                return "\(prefix)- {}"
            }
            var rendered = "\(prefix)- \(first.trimmingCharacters(in: .whitespaces))"
            if lines.count > 1 {
                rendered += "\n" + lines.dropFirst().joined(separator: "\n")
            }
            return rendered
        }.joined(separator: "\n")
    }

    func yamlKey(_ key: String) -> String {
        switch key {
        case "$ref":
            "\"$ref\""
        default:
            key
        }
    }

    func yamlString(_ string: String) -> String {
        guard needsQuotes(string) else {
            return string
        }
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func isScalar(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber:
            return true
        default:
            return false
        }
    }

    func needsQuotes(_ string: String) -> Bool {
        if string.isEmpty {
            return true
        }
        if string == "~" || string == "null" || string == "true" || string == "false" {
            return true
        }
        if string.contains(where: \.isWhitespace) {
            return true
        }
        let reserved = CharacterSet(charactersIn: ":{}[],&*#?|-<>=!%@`\"'")
        if string.rangeOfCharacter(from: reserved) != nil {
            return true
        }
        if string.first == "-" || string.first == "*" || string.first == "&" || string.first == "!" {
            return true
        }
        if Double(string) != nil {
            return true
        }
        return false
    }
}
