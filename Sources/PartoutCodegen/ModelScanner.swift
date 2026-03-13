// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import SwiftSyntax

final class ModelScanner: SyntaxVisitor {
    private(set) var results = IRContext()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        doVisit(node, parents: [])
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        doVisit(node, parents: [])
        return .skipChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        doVisit(node, parents: [])
        return .skipChildren
    }
}

private extension ModelScanner {
    func doVisit(_ node: ExtensionDeclSyntax, parents: [IRScope]) {
        let name = node.extendedType.trimmedDescription
        if let alias = findAlias(in: node.inheritanceClause, memberBlock: node.memberBlock, name: name, parents: parents) {
            results.aliases.append(alias)
            return
        }
        let newParents = parents + [.extension(name)]
        for member in node.memberBlock.members {
            if let structDecl = member.decl.as(StructDeclSyntax.self) {
                doVisit(structDecl, parents: newParents)
            } else if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
                doVisit(enumDecl, parents: newParents)
            }
        }
    }

    func doVisit(_ node: StructDeclSyntax, parents: [IRScope]) {
        let name = node.name.text
        // Express raw as typealias, not struct
        if let alias = findAlias(
            in: node.inheritanceClause,
            memberBlock: node.memberBlock,
            name: name,
            parents: parents
        ) {
            results.aliases.append(alias)
            return
        }
        let newParents = parents + [.struct(name)]
        let props = node.memberBlock.parseProperties(parents: newParents)
        results.models.append(IRModel(
            name: name,
            kind: .struct,
            properties: props,
            parents: parents
        ))
        for member in node.memberBlock.members {
            if let structDecl = member.decl.as(StructDeclSyntax.self) {
                doVisit(structDecl, parents: newParents)
            } else if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
                doVisit(enumDecl, parents: newParents)
            }
        }
    }

    func doVisit(_ node: EnumDeclSyntax, parents: [IRScope]) {
        let name = node.name.text
        let props = node.parseCases(parents: parents)
        results.models.append(IRModel(
            name: name,
            kind: .enum,
            properties: props,
            parents: parents
        ))
        let newParents = parents + [.enum(name)]
        for member in node.memberBlock.members {
            if let structDecl = member.decl.as(StructDeclSyntax.self) {
                doVisit(structDecl, parents: newParents)
            } else if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
                doVisit(enumDecl, parents: newParents)
            }
        }
    }

    func findAlias(
        in clause: InheritanceClauseSyntax?,
        memberBlock: MemberBlockSyntax,
        name: String,
        parents: [IRScope]
    ) -> IRAlias? {
        guard let clause, clause.conformsTo("RawRepresentable") else {
            return nil
        }
        let props = memberBlock.parseProperties(parents: parents, includingComputed: true)
        guard let rawValue = props.first(where: { $0.name == "rawValue" }) else { return nil }
        return IRAlias(name: name, kind: rawValue.type, parents: parents)
    }
}

// MARK: - Syntax

private extension EnumDeclSyntax {
    func parseCases(parents: [IRScope]) -> [IRProperty] {
        var cases: [IRProperty] = []
        for member in memberBlock.members {
            guard let enumCase = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in enumCase.elements {
                cases.append(IRProperty(
                    name: element.name.text,
                    type: .enumType(name.text),
                    scope: parents
                ))
            }
        }
        return cases
    }
}

private extension MemberBlockSyntax {
    func parseProperties(parents: [IRScope], includingComputed: Bool = false) -> [IRProperty] {
        var props: [IRProperty] = []
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard !varDecl.modifiers.contains(where: {
                ["static", "class"].contains($0.name.text)
            }) else { continue }
            for binding in varDecl.bindings {
                guard includingComputed || binding.accessorBlock == nil else { continue }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let name = pattern.identifier.text
                guard let typeSyntax = binding.typeAnnotation?.type else { continue }
                let irType = typeSyntax.irType(parents: parents)
                props.append(IRProperty(
                    name: name,
                    type: irType,
                    scope: parents
                ))
            }
        }
        return props
    }
}

private extension TypeSyntax {
    func irType(parents: [IRScope]) -> IRType {
        if let opt = self.as(OptionalTypeSyntax.self) {
            return .optional(opt.wrappedType.irType(parents: parents))
        } else if let arr = self.as(ArrayTypeSyntax.self) {
            return .array(arr.element.irType(parents: parents))
        } else if let dict = self.as(DictionaryTypeSyntax.self) {
            return .dictionary(
                key: dict.key.irType(parents: parents),
                value: dict.value.irType(parents: parents)
            )
        } else if let simple = self.as(IdentifierTypeSyntax.self) {
            let name = simple.trimmedDescription
            if name.hasPrefix("Set") {
                if let args = simple.genericArgumentClause?.arguments {
                    if let firstArg = args.first?.argument.as(TypeSyntax.self) {
                        return .set(firstArg.irType(parents: parents))
                    }
                }
            }
            switch name {
            case "String": return .string
            case "Int": return .int
            case "Bool": return .bool
            case "UUID": return .uuid
            case "URL": return .url
            case "Data": return .data
            case "Date": return .date
            case "Double", "TimeInterval": return .double
            case "JSON": return .json
            default:
                return .custom(withName: name, scope: parents)
            }
        } else if let member = self.as(MemberTypeSyntax.self) {
            return .custom(withName: member.trimmedDescription, scope: parents)
        } else {
            return .custom(withName: trimmedDescription, scope: parents)
        }
    }
}

private extension InheritanceClauseSyntax {
    func conformsTo(_ proto: String) -> Bool {
        inheritedTypes.contains {
            $0.type.trimmedDescription == proto
        }
    }
}

// MARK: - Helpers

private extension IRType {
    static func custom(withName typeName: String, scope: [IRScope]) -> IRType {
        .custom(search: { ctx in
            if let alias = ctx.aliases.first(where: { $0.name == typeName }) {
                return alias.fqTypeName
            }
            let matches = ctx.models.filter {
                $0.name == typeName
            }
            guard let found = matches.first else {
//                print("IRModel: Unable to find for \(typeName)")
                return nil
            }
            guard matches.count == 1 else {
                fatalError("IRModel: Multiple matches for \(typeName): \(matches)")
            }
//            print("IRModel: Found for \(typeName): \(found.name)")
            return found.fqTypeName
        }, fallback: typeName)
    }
}
