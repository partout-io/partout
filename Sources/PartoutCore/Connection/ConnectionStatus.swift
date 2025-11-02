// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The status of a ``Connection``.
@frozen
public enum ConnectionStatus: String, Codable {
    case disconnected

    case connecting

    case connected

    case disconnecting
}

extension ConnectionStatus {
    func canChange(to nextStatus: ConnectionStatus) -> Bool {
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
