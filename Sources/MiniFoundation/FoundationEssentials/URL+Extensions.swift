// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension URL {
    public func filePath() -> String {
        // XXX: This should be equal to .path(percentEncoded: false)
        // i.e. false means "not percent encoded" = "after decoding percents"
        assert(isFileURL)
        return path
    }
}
