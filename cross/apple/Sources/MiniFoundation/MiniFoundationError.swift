// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public enum MiniFoundationError: Error {
    case io(Int? = nil)
    case encoding
    case decoding
}
