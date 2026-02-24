// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension URL: MiniURLProtocol {
    public func filePath() -> String {
        // XXX: This should be equal to .path(percentEncoded: false)
        // i.e. false means "not percent encoded" = "after decoding percents"
        assert(isFileURL)
        return path
    }

    public func miniAppending(component: String) -> URL {
        appending(component: component)
    }

    public func miniAppending(path: String) -> URL {
        appendingPathComponent(path)
    }

    public func miniAppending(pathExtension: String) -> URL {
        appendingPathExtension(pathExtension)
    }

    public func miniDeletingLastPathComponent() -> URL {
        deletingLastPathComponent()
    }
}
