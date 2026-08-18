// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelStatus {
    public func considering(_ environment: TunnelSnapshot.Environment?) -> TunnelStatus {
        if self == .active,
           let environment {
            switch environment.connectionStatus {
            case .connecting:
                return .activating
            case .connected:
                return .active
            case .disconnecting:
                return .deactivating
            case .disconnected:
                // The provider is still alive, so a disconnected connection
                // without an error is either starting or waiting to retry.
                // Keep it pending while the separately reported error catches up.
                return environment.lastErrorCode == nil ? .activating : .inactive
            }
        }
        return self
    }
}
