// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension NWConnection.State: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .cancelled: return "cancelled"
        case .failed(let error): return "failed (\(error.localizedDescription))"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .setup: return "setup"
        case .waiting(let error): return "waiting (\(error.localizedDescription))"
        @unknown default: return "???"
        }
    }
}
