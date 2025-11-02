// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

public typealias TimeInterval = Double

public struct Date: Hashable, Comparable, Codable, Sendable {
    public init() {
        fatalError()
    }

    public init(timeIntervalSinceNow: TimeInterval) {
        fatalError()
    }

    public static func < (lhs: Date, rhs: Date) -> Bool {
        fatalError()
    }

    public var timeIntervalSince1970: UInt32 {
        fatalError()
    }

    public var timeIntervalSinceNow: TimeInterval {
        fatalError()
    }

    public func addingTimeInterval(_ timeInterval: TimeInterval) -> Date {
        fatalError()
    }
}
