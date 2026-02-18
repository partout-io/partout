// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension URL: MiniURLProtocol {
    public func filePath() -> String {
        // FIXME: #303, Is .path(percentEncoded: false|true) the same?
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
