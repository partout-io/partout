// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol MiniURLProtocol: Sendable {
    var scheme: String? { get }
    var host: String? { get }
    var port: Int? { get }
    var query: String? { get }
    var fragment: String? { get }
    var absoluteString: String { get }
    // File URLs
    func filePath() -> String
    var lastPathComponent: String { get }
    func appendingPathExtension(_ extension: String) -> Self
    func appendingPathComponent(_ component: String) -> Self
    func deletingLastPathComponent() -> Self
}
