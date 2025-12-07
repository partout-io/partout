// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension URL: MiniURLProtocol {
    public func filePath() -> String {
        // FIXME: #228, Is .path(percentEncoded: false|true) the same?
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
