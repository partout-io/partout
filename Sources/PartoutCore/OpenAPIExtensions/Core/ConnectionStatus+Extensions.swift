// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ConnectionStatus {
    public func canChange(to nextStatus: ConnectionStatus) -> Bool {
        switch self {
        case .connected:
            return [.connecting, .disconnecting, .disconnected]
                .contains(nextStatus)
        case .connecting:
            return [.connected, .disconnecting, .disconnected]
                .contains(nextStatus)
        case .disconnecting:
            return nextStatus == .disconnected
        case .disconnected:
            return nextStatus == .connecting
        }
    }
}

extension ConnectionStatus: CustomDebugStringConvertible {
    public var debugDescription: String {
        rawValue
    }
}
