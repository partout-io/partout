// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension FileManager {
    public func makeTemporaryURL(filename: String) -> URL {
        temporaryDirectory.appending(component: filename)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let items = try contentsOfDirectory(atPath: url.filePath())
        return items.map {
            URL(filePath: $0, relativeTo: url)
        }
    }
}
