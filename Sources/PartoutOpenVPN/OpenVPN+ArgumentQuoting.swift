// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension String {
    func asOpenVPNQuotedArgument() -> String {
        let quote: Character
        if !contains("'") {
            quote = "'"
        } else if !contains("\"") {
            quote = "\""
        } else {
            quote = "'"
        }

        var escaped = String()
        escaped.reserveCapacity(count)
        for character in self {
            if character == "\\" || character == quote {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\(quote)\(escaped)\(quote)"
    }

    func removingOpenVPNArgumentQuotes() -> String {
        guard let first, first == last, first == "'" || first == "\"" else {
            return self
        }

        var unquoted = String()
        unquoted.reserveCapacity(count - 2)
        var isEscaped = false
        for character in dropFirst().dropLast() {
            if isEscaped {
                unquoted.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            unquoted.append(character)
        }
        if isEscaped {
            unquoted.append("\\")
        }
        return unquoted
    }
}
