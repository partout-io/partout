// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension FileManager {
    public func makeTemporaryURL(filename: String) -> URL {
        temporaryDirectory.appending(component: filename)
    }
}
