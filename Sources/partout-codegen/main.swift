// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
import PartoutCodegen
import SwiftParser

do {
    let args = CommandLine.arguments
    guard args.count > 1 else {
        let known = Codegen.Output.allCases
            .map(\.rawValue)
            .joined(separator: "|")
        fatalError("Missing encoder name (\(known))")
    }
    let encoderName = args[1]

    let encoder: CodegenEncoder
    switch Codegen.Output(rawValue: encoderName) {
    case .swift:
        encoder = SwiftEncoder()
    case .kotlin:
        encoder = KotlinEncoder(
            packageName: "io.partout.abi"
        )
    case .cxx:
        fatalError("C++ encoder not implemented")
    default:
        fatalError("Unknown encoder '\(encoderName)'")
    }
    let codegen = Codegen(encoder: encoder)
    let output = try codegen.generate(
        from: PartoutCodegen.paths.map { "Sources/\($0)" },
        entities: PartoutCodegen.entities
    )
    print(output)
} catch {
    print(error)
}
