// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public enum MiniFoundation {
}

public enum MiniFoundationError: Error {
    case io(Int? = nil)
    case encoding
    case decoding
    case file(MiniFileManagerError)
}

public enum MiniFileManagerError: Error {
    case failedToOpenDirectory(String)
    case failedToStat(String)
    case failedToMove(String, String)
    case failedToRemove(String)
}
