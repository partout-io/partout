// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C

extension Compat {
    public typealias TimeInterval = Double

    public struct Date: Hashable, Comparable, Codable, Sendable {
        private let secondsSinceEpoch: TimeInterval

        public init() {
            self.init(timeIntervalSinceNow: 0)
        }

        public init(timeIntervalSinceNow: TimeInterval) {
            secondsSinceEpoch = Date.nowInterval + timeIntervalSinceNow
        }

        public init(timeIntervalSince1970: TimeInterval) {
            secondsSinceEpoch = timeIntervalSince1970
        }

        public var timeIntervalSince1970: TimeInterval {
            secondsSinceEpoch
        }

        public var timeIntervalSinceNow: TimeInterval {
            secondsSinceEpoch - Date.nowInterval
        }

        public func addingTimeInterval(_ timeInterval: TimeInterval) -> Self {
            Date(timeIntervalSince1970: timeIntervalSince1970 + timeInterval)
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.secondsSinceEpoch < rhs.secondsSinceEpoch
        }

        private static var nowInterval: TimeInterval {
            TimeInterval(Date.currentUnixTime())
        }

        private static func currentUnixTime() -> UInt64 {
            var t: time_t = 0
            time(&t)
            return UInt64(t)
        }
    }
}

extension Compat.Date {
    private static let appleEpoch: Compat.TimeInterval = 978_307_200

    public static var distantPast: Self {
        Self(timeIntervalSince1970: -.infinity)
    }

    public static var distantFuture: Self {
        Self(timeIntervalSince1970: .infinity)
    }

    public init(timeIntervalSinceReferenceDate interval: Compat.TimeInterval) {
        self.init(timeIntervalSince1970: interval + Self.appleEpoch)
    }

    public var timeIntervalSinceReferenceDate: Compat.TimeInterval {
        secondsSinceEpoch - Self.appleEpoch
    }
}
