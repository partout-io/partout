// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public final class FileManager: Sendable {
    public static let `default` = FileManager()

    public func attributesOfItem(atPath path: String) throws -> [FileAttribute: Any] {
        fatalError()
    }

    public func moveItem(at url: URL, to toURL: URL) throws {
        fatalError()
    }

    public func removeItem(at url: URL) throws {
        fatalError()
    }

    public func fileExists(atPath path: String) -> Bool {
        fatalError()
    }
}

public enum FileAttribute {
    case size

    case modificationDate
}

public struct FileHandle {
    public init(forUpdating url: URL) throws {
        fatalError()
    }

    public func seekToEnd() throws {
    }

    public func write(contentsOf data: Data) throws {
    }
}
