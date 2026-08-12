// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if !MINIF_COMPAT
extension FileManager {
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}
#endif
