// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol MiniFileManager: AnyObject, Sendable {
    func makeTemporaryPath(filename: String) -> String
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func miniAttributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any]
    func moveItem(atPath path: String, toPath: String) throws
    func removeItem(atPath path: String) throws
    func fileExists(atPath path: String) -> Bool
}

public enum MiniFileAttribute {
    case size
    case creationDate
    case modificationDate
}
