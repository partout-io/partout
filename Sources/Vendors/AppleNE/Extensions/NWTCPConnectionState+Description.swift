// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension

extension NWTCPConnectionState: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .cancelled: return "cancelled"
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        case .invalid: return "invalid"
        case .waiting: return "waiting"
        @unknown default: return "???"
        }
    }
}
