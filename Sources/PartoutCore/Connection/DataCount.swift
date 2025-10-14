// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// A pair of received/sent bytes count.
public struct DataCount: Hashable, Codable, Sendable {

    /// Received bytes count.
    public let received: UInt

    /// Sent bytes count.
    public let sent: UInt

    public init(_ received: UInt = .zero, _ sent: UInt = .zero) {
        self.received = received
        self.sent = sent
    }

    public func adding(_ other: DataCount) -> Self {
        adding(other.received, other.sent)
    }

    public func adding(_ received: UInt, _ sent: UInt) -> Self {
        DataCount(self.received + received, self.sent + sent)
    }
}

extension DataCount: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{in=\(received), out=\(sent)}"
    }
}
