// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public struct URL: Hashable, Codable, Sendable {
    public init?(string: String) {
        fatalError()
    }

    public init(fileURLWithPath path: String) {
        fatalError()
    }

    public var absoluteString: String {
        fatalError()
    }

    public var scheme: String {
        fatalError()
    }

    public var path: String {
        fatalError()
    }

    public func appendingPathExtension(_ extension: String) -> URL {
        fatalError()
    }

    public func appendingPathComponent(_ component: String) -> URL {
        fatalError()
    }

    public func deletingLastPathComponent() -> URL {
        fatalError()
    }

    public var lastPathComponent: String {
        fatalError()
    }
}
