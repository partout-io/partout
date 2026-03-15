// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public struct KotlinSealedMetadata {
    let classes: [KotlinSealedClass]
    let baseClass: (_ fqTypeName: String) -> String?
    public init(classes: [KotlinSealedClass], baseClass: @escaping (_: String) -> String?) {
        self.classes = classes
        self.baseClass = baseClass
    }
}

public struct KotlinSealedClass {
    let name: String
    let discriminator: String
    public init(name: String, discriminator: String) {
        self.name = name
        self.discriminator = discriminator
    }
}

final class KotlinEncoder: IREncoder {
    private let packageName: String
    private let preamble: String?
    private let sealed: KotlinSealedMetadata?
    private let replacement: ((String) -> String?)?
    private let skipsProperty: ((_ name: String, _ fqModelName: String) -> Bool)?

    init(
        packageName: String,
        preamble: String?,
        sealed: KotlinSealedMetadata?,
        replacement: ((String) -> String?)?,
        skipsProperty: ((_ name: String, _ fqTypeName: String) -> Bool)?
    ) {
        self.packageName = packageName
        self.preamble = preamble
        self.sealed = sealed
        self.replacement = replacement
        self.skipsProperty = skipsProperty
    }

    func encodePreamble() -> String? {
        var desc = """
package \(packageName)

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

"""
        if let preamble {
            desc.append(preamble)
            desc.append("\n")
        }
        if let sealed {
            desc.append("""
import kotlinx.serialization.json.JsonClassDiscriminator
import kotlinx.serialization.json.JsonElement

""")
            sealed.classes.forEach {
                desc += """

@Serializable
@JsonClassDiscriminator("\($0.discriminator)")
sealed class \($0.name)
"""
            }
        }
        return desc
    }

    func encode(_ model: IRModel, ctx: IRContext) -> String {
        var desc: [String] = []
        let fqTypeName = normalizedTypeName(model.fqTypeName)
        desc.append("@Serializable")
        desc.append("@SerialName(\"\(fqTypeName)\")")
        switch model.kind {
        case .enum:
            desc.append("enum class \(fqTypeName) {")
            model.properties.forEach {
                desc.append("    \($0.name),")
            }
            desc.append("}")
        case .struct:
            let filteredProps = model.properties.filter {
                !skipsProperty(withName: $0.name, fqModelName: fqTypeName)
            }
            if !filteredProps.isEmpty {
                desc.append("data class \(fqTypeName)(")
            } else {
                desc.append("class \(fqTypeName)(")
            }
            filteredProps.forEach {
                let typeName = encode($0.type, ctx: ctx)
                desc.append("    val \($0.name.normalizedIdentifier): \(normalizedTypeName(typeName)),")
            }
            if let sealed, let baseClass = sealed.baseClass(fqTypeName) {
                desc.append(") : \(baseClass)()")
            } else {
                desc.append(")")
            }
        }
        return desc.joined(separator: "\n")
    }

    func encode(_ alias: IRAlias, ctx: IRContext) -> String {
        "typealias \(normalizedTypeName(alias.fqTypeName)) = \(encode(alias.kind, ctx: ctx))"
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
            "Boolean"
        case .uuid:
            "UUID"
        case .url:
            "String"
        case .data:
            "ByteArray"
        case .date:
            "String"
        case .json:
            "JsonElement"
        case .optional(let wrapped):
            "\(encode(wrapped, ctx: ctx))? = null"
        case .array(let element):
            "List<\(encode(element, ctx: ctx))>"
        case .dictionary(let key, let value):
            "Map<\(encode(key, ctx: ctx)), \(encode(value, ctx: ctx))>"
        case .set(let element):
            "Set<\(encode(element, ctx: ctx))>"
        case .enumType(let name):
            normalizedTypeName(name)
        case .unresolved(let name):
            normalizedTypeName(name)
        case .custom(let search, let fallback):
            normalizedTypeName(search(ctx) ?? fallback)
        }
    }
}

private extension String {
    var normalizedIdentifier: String {
        switch self {
        case "interface": "`\(self)`"
        default: self
        }
    }

}

private extension KotlinEncoder {
    func normalizedTypeName(_ typeName: String) -> String {
        switch typeName {
        case "Int8", "Int16", "Int32", "Int64":
            return "Int"
        case "Profile.ID":
            return "String"
        case "SecureData":
            return "ByteArray"
        case "TimeInterval":
            return "Double"
        case "UInt8", "UInt16", "UInt32", "UInt64":
            return "UInt"
        case "UniqueID":
            return "String"
        default:
            if let replacement, let newName = replacement(typeName) {
                return newName
            }
            return typeName.replacingOccurrences(of: ".", with: "_")
        }
    }

    func skipsProperty(withName name: String, fqModelName: String) -> Bool {
        skipsProperty?(name, fqModelName) ?? false
    }
}
