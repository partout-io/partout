// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINIF_COMPAT
extension String {
    public func strippingWhitespaces() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    public func write(toFile path: String, encoding: String.Encoding) throws {
        try write(toFile: path, atomically: true, encoding: encoding)
    }

    public func append(toFile path: String, encoding: String.Encoding) throws {
        guard let file = FileHandle(forUpdatingAtPath: path) else {
            throw MiniFoundationError.io()
        }
        try file.seekToEnd()
        if let data = data(using: encoding) {
            try file.write(contentsOf: data)
        }
    }
}
#endif
