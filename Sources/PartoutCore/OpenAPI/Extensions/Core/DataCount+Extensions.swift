// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
extension DataCount {
    public static let zero = DataCount()

    public init(_ received: UInt64 = .zero, _ sent: UInt64 = .zero) {
        self.init(received: received, sent: sent)
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
