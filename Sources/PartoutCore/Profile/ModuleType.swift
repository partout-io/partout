// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Raw type univocally associated to each ``Module`` implementation.
public struct ModuleType: RawRepresentable, Identifiable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ name: String) {
        self.init(rawValue: name)
    }

    public var id: String {
        rawValue
    }
}

extension ModuleType {

    // WARNING: retain this for legacy persisted profiles
    private enum CodingKeys: CodingKey {
        case name
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let name = try container.decode(String.self)
            self.init(rawValue: name)
        } catch {
            // legacy encoding
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .name)
            self.init(rawValue: name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ModuleType: CustomDebugStringConvertible {
    public var debugDescription: String {
        rawValue
    }
}
