// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if MINIF_COMPAT
extension FileManager {
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let standardURL = url.standardizedFileURL
        let items = try contentsOfDirectory(atPath: standardURL.filePath())
        return items.map {
            URL(filePath: $0, relativeTo: url)
        }
    }
}
#endif
