// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

public struct NativeURL: MiniURLProtocol, Equatable, Hashable, Codable, Sendable {
    public let foundationURL: Foundation.URL

    public init?(string: String) {
        guard let url = Foundation.URL(string: string) else { return nil }
        self.init(url)
    }

    public init(_ url: Foundation.URL) {
        foundationURL = url
    }

    public var scheme: String? {
        foundationURL.scheme
    }

    public var host: String? {
        foundationURL.host(percentEncoded: true)
    }

    public var port: Int? {
        foundationURL.port
    }

    public var path: String {
        // FIXME: #228, Is this equal to deprecated .path ?
        foundationURL.path(percentEncoded: true)
    }

    public var lastPathComponent: String {
        foundationURL.lastPathComponent
    }

    public var query: String? {
        foundationURL.query(percentEncoded: true)
    }

    public var fragment: String? {
        foundationURL.fragment(percentEncoded: true)
    }

    public var absoluteString: String {
        foundationURL.absoluteString
    }

    public var description: String {
        foundationURL.absoluteString
    }

    // MARK: Codable

    // This is VERY IMPORTANT to retain serialization behavior
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        foundationURL = try container.decode(Foundation.URL.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(foundationURL)
    }
}
