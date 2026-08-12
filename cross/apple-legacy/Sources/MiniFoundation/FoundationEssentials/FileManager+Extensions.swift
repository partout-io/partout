// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

@_exported @testable import PartoutCore

extension FileManager {
    public func makeTemporaryURL(filename: String) -> URL {
        temporaryDirectory.appending(component: filename)
    }
}
