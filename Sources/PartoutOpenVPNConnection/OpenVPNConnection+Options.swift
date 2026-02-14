// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNConnection {
    /// Intervals are expressed in seconds.
    public struct Options: Sendable {
        public var maxPackets: Int = 100

        public var writeTimeout: TimeInterval = 5.0

        public var minDataCountInterval: TimeInterval = 3.0

        public var negotiationTimeout: TimeInterval = 30.0

        public var hardResetTimeout: TimeInterval = 10.0

        public var tickInterval: TimeInterval = 0.2

        public var retxInterval: TimeInterval = 0.1

        public var pushRequestInterval: TimeInterval = 2.0

        public var pingTimeoutCheckInterval: TimeInterval = 10.0

        public var pingTimeout: TimeInterval = 120.0

        public var softNegotiationTimeout: TimeInterval = 120.0

        public init() {
        }
    }
}
