// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol MiniRegularExpression: Sendable {
    func enumerateMatches(in string: String, using block: @escaping (String) -> Void)
}
