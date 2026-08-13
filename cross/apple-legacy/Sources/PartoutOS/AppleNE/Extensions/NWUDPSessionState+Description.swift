// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NWUDPSessionState: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .invalid: return "invalid"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting: return "waiting"
        @unknown default: return "???"
        }
    }
}
