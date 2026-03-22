// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
import PartoutCodegen
import SwiftParser

do {
    let args = CommandLine.arguments
    guard args.count > 2 else {
        let known = Codegen.Output.allCases
            .map(\.rawValue)
            .joined(separator: "|")
        fatalError("Missing arguments: <encoder (\(known))> <output-dir> [root]")
    }
    let encoderName = args[1]
    let outputPath = args[2]
    let root = args.count > 3 ? args[3] : "."

    let output: Codegen.Output
    let encoder: CodegenEncoder
    switch Codegen.Output(rawValue: encoderName) {
    case .openapi:
        output = .openapi
        encoder = OpenAPIEncoder()
    default:
        fatalError("Unknown encoder '\(encoderName)'")
    }
    let codegen = try Codegen(
        from: PartoutCodegen.paths.map {
            "\(root)/Sources/\($0)"
        },
        entities: PartoutCodegen.entities
    )
    let fm: FileManager = .default
    let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
    try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
    switch output {
    case .openapi:
        let generated = try codegen.generate(encoder: encoder)
        let fileURL = outputURL
            .appendingPathComponent(output.fileName)
            .appendingPathExtension(output.fileExtension)
        try generated.write(to: fileURL, atomically: true, encoding: .utf8)
    }
} catch {
    print(error)
}

private extension Codegen.Output {
    var fileName: String {
        rawValue
    }

    var fileExtension: String {
        switch self {
        case .openapi:
            "yaml"
        }
    }
}
