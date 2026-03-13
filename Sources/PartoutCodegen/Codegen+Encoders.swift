// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension Codegen {
    public enum Output: String, CaseIterable {
        case swift
        case kotlin
        case cxx
    }

    public static func forSwift() -> Codegen {
        Codegen(encoder: SwiftEncoder())
    }

    public static func forKotlin(
        packageName: String,
        preamble: String? = nil,
        sealed: KotlinSealedMetadata? = nil,
        replacement: ((String) -> String)? = nil,
        skipsProperty: ((_ name: String, _ fqModelName: String) -> Bool)? = nil
    ) -> Codegen {
        Codegen(encoder: KotlinEncoder(
            packageName: packageName,
            preamble: preamble,
            sealed: sealed,
            replacement: replacement,
            skipsProperty: skipsProperty
        ))
    }
}
