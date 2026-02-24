// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension Error {
    public var localizedDescription: String {
        // XXX: No clue, but error description _should_ fall back to a string representation
        String(describing: self)
    }
}
