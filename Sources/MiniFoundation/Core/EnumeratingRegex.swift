// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol EnumeratingRegex: Sendable {
    func enumerateMatches(in string: String, using block: @escaping @Sendable (String) -> Void)
}
