// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public protocol MiniURLProtocol: Sendable {
    var scheme: String? { get }
    var host: String? { get }
    var port: Int? { get }
    var path: String { get }
    var lastPathComponent: String { get }
    var query: String? { get }
    var fragment: String? { get }
    var absoluteString: String { get }
    // File URLs
    func filePath() -> String
    func miniAppending(component: String) -> Self
    func miniAppending(path: String) -> Self
    func miniAppending(pathExtension: String) -> Self
    func miniDeletingLastPathComponent() -> Self
}
