// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension String {
    public func write(toFile path: String) throws {
        try write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func append(toFile path: String) throws {
        guard let file = FileHandle(forUpdatingAtPath: path) else {
            throw MiniFoundationError.io()
        }
        try file.seekToEnd()
        if let data = data(using: .utf8) {
            try file.write(contentsOf: data)
        }
    }

    public func strippingWhitespaces() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s", with: " ", options: .regularExpression)
    }
}
