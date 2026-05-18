// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A pair of received/sent bytes count.
public struct DataCount: Hashable, Codable, Sendable {
    public static let zero = DataCount()

    /// Received bytes count.
    public let received: UInt64

    /// Sent bytes count.
    public let sent: UInt64

    public init(_ received: UInt64 = .zero, _ sent: UInt64 = .zero) {
        self.received = received
        self.sent = sent
    }

    public func adding(_ other: DataCount) -> Self {
        adding(other.received, other.sent)
    }

    public func adding(_ received: UInt64, _ sent: UInt64) -> Self {
        DataCount(self.received + received, self.sent + sent)
    }
}

extension DataCount: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{in=\(received), out=\(sent)}"
    }
}
