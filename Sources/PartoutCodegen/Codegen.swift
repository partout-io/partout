// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
import SwiftParser

public final class Codegen {
    private let encoder: IREncoder

    init(encoder: IREncoder) {
        self.encoder = encoder
    }

    public func generate(from paths: [String], entities: [String]) throws -> String {
        let ctx = try scanDirectories(paths: paths)
        var lines: [String] = []
        var undefinedEntities = Set(entities)
        if let preamble = encoder.encodePreamble() {
            lines.append(preamble)
            lines.append("")
        }
        for model in ctx.models {
            let fq = model.fqTypeName
            guard entities.contains(fq) else { continue }
            guard !ctx.aliases.contains(where: { $0.name == model.name }) else { continue }
            lines.append(encoder.encode(model, ctx: ctx))
            lines.append("")
            undefinedEntities.remove(model.fqTypeName)
        }
        for alias in ctx.aliases {
            lines.append(encoder.encode(alias, ctx: ctx))
            lines.append("")
            undefinedEntities.remove(alias.fqTypeName)
        }
        // Make sure that all entities exist in the output
        assert(undefinedEntities.isEmpty)
        return lines.joined(separator: "\n")
    }
}

private extension Codegen {
    func scanDirectories(paths: [String]) throws -> IRContext {
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

    func scanFile(path: String) throws -> IRContext {
        let url = URL(fileURLWithPath: path)
        let source = try Parser.parse(source: String(contentsOf: url))
        let scanner = ModelScanner(viewMode: .all)
        scanner.walk(source)
        return scanner.results
    }
}
