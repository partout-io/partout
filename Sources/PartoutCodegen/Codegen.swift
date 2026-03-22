// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
import SwiftParser

public protocol CodegenEncoder {}

// Rough way to imply CodegenEncoder from IREncoder conformance
extension OpenAPIEncoder: CodegenEncoder, IREncoder {}

public final class Codegen {
    public enum Output: String, CaseIterable {
        case openapi
    }

    public let ctx: IRContext

    public init(from paths: [String], entities: [String]) throws {
        var ctx = try Self.scanDirectories(paths: paths)
        let aliasesNames = ctx.aliases.map(\.fqTypeName)
        ctx.models = ctx.models.filter {
            entities.contains($0.fqTypeName) && !aliasesNames.contains($0.fqTypeName)
        }
        ctx.aliases = ctx.aliases.filter {
            entities.contains($0.fqTypeName)
        }
        // Inject a few hardcoded ones
        ctx.aliases.append(contentsOf: [
            IRAlias(name: "SecureData", kind: .string, parents: []),
            IRAlias(name: "UInt16", kind: .int, parents: []),
            IRAlias(name: "UInt32", kind: .int, parents: []),
            IRAlias(name: "UInt64", kind: .int, parents: []),
            IRAlias(name: "UniqueID", kind: .string, parents: [])
        ])
        // Make sure that all entities exist in the output
        var undefinedEntities = Set(entities)
        for model in ctx.models {
            guard !ctx.aliases.contains(where: { $0.name == model.name }) else { continue }
            undefinedEntities.remove(model.fqTypeName)
        }
        for alias in ctx.aliases {
            undefinedEntities.remove(alias.fqTypeName)
        }
        assert(undefinedEntities.isEmpty)

        // Finalize initialization
        self.ctx = ctx
    }

    public func generate(encoder: CodegenEncoder) throws -> String {
        guard let encoder = encoder as? IREncoder else {
            fatalError("\(encoder) is not a IREncoder")
        }
        if let document = encoder.encodeDocument(ctx: ctx) {
            return renderedContents(body: document, preamble: encoder.encodePreamble())
        }
        var lines: [String] = []
        if let preamble = encoder.encodePreamble() {
            lines.append(preamble)
            lines.append("")
        }
        for model in ctx.models {
            guard !ctx.aliases.contains(where: { $0.name == model.name }) else { continue }
            lines.append(encoder.encode(model, ctx: ctx))
            lines.append("")
        }
        for alias in ctx.aliases {
            lines.append(encoder.encode(alias, ctx: ctx))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func generateFiles(encoder: CodegenEncoder) throws -> [(name: String, contents: String)] {
        guard let encoder = encoder as? IREncoder else {
            fatalError("\(encoder) is not a IREncoder")
        }
        var files: [(name: String, contents: String)] = []
        for model in ctx.models {
            guard !ctx.aliases.contains(where: { $0.name == model.name }) else { continue }
            files.append((
                name: model.fqTypeName,
                contents: renderedContents(
                    body: encoder.encode(model, ctx: ctx),
                    preamble: encoder.encodePreamble()
                )
            ))
        }
        for alias in ctx.aliases {
            files.append((
                name: alias.fqTypeName,
                contents: renderedContents(
                    body: encoder.encode(alias, ctx: ctx),
                    preamble: encoder.encodePreamble()
                )
            ))
        }
        return files
    }
}

private extension Codegen {
    func renderedContents(body: String, preamble: String?) -> String {
        guard let preamble else {
            return body
        }
        return "\(preamble)\n\n\(body)"
    }

    static func scanDirectories(paths: [String]) throws -> IRContext {
        let fm: FileManager = .default
        var result = IRContext()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let files = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
            for file in files where file.pathExtension == "swift" {
                let partial = try scanFile(path: file.path)
                result.merge(partial)
            }
        }
        return result
    }

    static func scanFile(path: String) throws -> IRContext {
        let url = URL(fileURLWithPath: path)
        let source = try Parser.parse(source: String(contentsOf: url))
        let scanner = ModelScanner(viewMode: .all)
        scanner.walk(source)
        return scanner.results
    }
}
