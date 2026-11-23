// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Wraps up a timestamped debug log.
public struct DebugLog: Hashable, Codable, Sendable {

    @frozen
    public enum Level: Int, Comparable, Codable, Sendable {
        case fault

        case error

        case notice

        case info

        case debug

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Line: Hashable, Codable, Sendable {
        public let timestamp: Date

        public let level: Level

        public let message: String

        public init(timestamp: Date, level: Level, message: String) {
            self.timestamp = timestamp
            self.level = level
            self.message = message
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }
}
