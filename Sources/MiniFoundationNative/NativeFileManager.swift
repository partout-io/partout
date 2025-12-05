// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension FileManager: MiniFileManager {
    public func makeTemporaryPath(filename: String) -> String {
        temporaryDirectory.appending(component: filename).filePath()
    }

    public func miniAttributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        try attributesOfItem(atPath: path)
            .reduce(into: [:]) {
                guard let key = $1.key.toMini else { return } // Ignored attribute
                $0[key] = $1.value
            }
    }
}

private extension FileAttributeKey {
    var toMini: MiniFileAttribute? {
        switch self {
        case .creationDate: return .creationDate
        case .modificationDate: return .modificationDate
        case .size: return .size
        default: return nil
        }
    }
}
