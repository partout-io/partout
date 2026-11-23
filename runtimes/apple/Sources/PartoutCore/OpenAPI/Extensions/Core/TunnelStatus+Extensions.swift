// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelStatus {
    public func considering(_ environment: TunnelSnapshot.Environment?) -> TunnelStatus {
        if self == .active,
           let connectionStatus = environment?.connectionStatus {
            switch connectionStatus {
            case .connecting:
                return .activating
            case .connected:
                return .active
            case .disconnecting:
                return .deactivating
            case .disconnected:
                return .inactive
            }
        }
        return self
    }
}
