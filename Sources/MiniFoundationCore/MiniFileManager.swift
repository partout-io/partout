// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol MiniFileManager: AnyObject, Sendable {
    func makeTemporaryPath(filename: String) -> String
    func miniContentsOfDirectory(at url: MiniURLProtocol) throws -> [MiniURLProtocol]
    func miniMoveItem(at url: MiniURLProtocol, to: MiniURLProtocol) throws
    func miniRemoveItem(at url: MiniURLProtocol) throws
    func attributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any]
    func fileExists(atPath path: String) -> Bool
}

public enum MiniFileAttribute {
    case size
    case creationDate
    case modificationDate
}
