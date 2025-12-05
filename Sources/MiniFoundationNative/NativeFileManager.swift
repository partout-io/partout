// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

public final class NativeFileManager: MiniFileManager {
    public static let `default`: MiniFileManager = NativeFileManager()

    public static var foundationManager: FileManager {
        .default
    }

    private var fm: FileManager {
        .default
    }

    private init() {
    }

    public func makeTemporaryPath(filename: String) -> String {
        fm.temporaryDirectory.appending(component: filename).path()
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: path)
    }

    public func attributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        try fm.attributesOfItem(atPath: path)
            .reduce(into: [:]) {
                guard let key = $1.key.toMini else { return } // Ignored attribute
                $0[key] = $1.value
            }
    }

    public func moveItem(atPath path: String, toPath: String) throws {
        try fm.moveItem(atPath: path, toPath: toPath)
    }

    public func removeItem(atPath path: String) throws {
        try fm.removeItem(atPath: path)
    }

    public func fileExists(atPath path: String) -> Bool {
        fm.fileExists(atPath: path)
    }
}

private extension FileAttributeKey {
    var toMini: MiniFileAttribute? {
        switch self {
        case .modificationDate: return .modificationDate
        case .size: return .size
        default: return nil
        }
    }
}
