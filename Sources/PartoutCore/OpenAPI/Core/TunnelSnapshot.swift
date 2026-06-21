// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Returns a tunnel-specific snapshot of a ``Profile``.
public struct TunnelSnapshot: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Environment: Hashable, Codable, Sendable {
        public private(set) var connectionStatus: ConnectionStatus

        public private(set) var dataCount: DataCount

        public private(set) var lastErrorCode: Int?

        public init(
            connectionStatus: ConnectionStatus = .disconnected,
            dataCount: DataCount = DataCount(),
            lastErrorCode: Int? = nil
        ) {
            self.connectionStatus = connectionStatus
            self.dataCount = dataCount
            self.lastErrorCode = lastErrorCode
        }

        public func with(connectionStatus: ConnectionStatus) -> Self {
            var copy = self
            copy.connectionStatus = connectionStatus
            return copy
        }

        public func with(dataCount: DataCount) -> Self {
            var copy = self
            copy.dataCount = dataCount
            return copy
        }

        public func with(lastErrorCode: Int) -> Self {
            var copy = self
            copy.lastErrorCode = lastErrorCode
            return copy
        }

        public func with(lastErrorCode: PartoutError.Code) -> Self {
            with(lastErrorCode: lastErrorCode.rawValue)
        }
    }

    public let id: UniqueID

    public let isEnabled: Bool

    public let status: TunnelStatus

    public let onDemand: Bool

    public private(set) var environment: Environment?

    public init(id: Profile.ID, isEnabled: Bool, status: TunnelStatus, onDemand: Bool, environment: Environment? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.status = status
        self.onDemand = onDemand
        self.environment = environment
    }

    public func with(environment: Environment?) -> Self {
        var copy = self
        copy.environment = environment
        return copy
    }

    public func isEquivalentExceptDataCount(to other: Self) -> Bool {
        let e1 = environment?.with(dataCount: .zero)
        let e2 = other.environment?.with(dataCount:.zero)
        return with(environment: e1) == other.with(environment: e2)
    }

    public var description: String {
        "{\(id.uuidString), isEnabled=\(isEnabled), status=\(status), onDemand=\(onDemand), environment=\(environment.debugDescription)}"
    }
}

/// Callback reporting ``TunnelSnapshot``.
public typealias OnTunnelSnapshotCallback = @Sendable (TunnelSnapshot) -> Void

extension TunnelStatus {
    public func considering(_ environment: TunnelSnapshot.Environment?) -> TunnelStatus {
        // If the tunnel is active and it relies on a
        // connection, map to the connection status
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
        // Otherwise, map directly to the tunnel status
        return self
    }
}

extension TunnelEnvironmentReader {
    public var snapshot: TunnelSnapshot.Environment {
        let connectionStatus = environmentValue(forKey: TunnelEnvironmentKeys.connectionStatus)
        let dataCount = environmentValue(forKey: TunnelEnvironmentKeys.dataCount)
        let lastError = environmentValue(forKey: TunnelEnvironmentKeys.lastErrorCode)
        return TunnelSnapshot.Environment(
            connectionStatus: connectionStatus ?? .disconnected,
            dataCount: dataCount ?? DataCount(),
            lastErrorCode: lastError?.rawValue
        )
    }
}
