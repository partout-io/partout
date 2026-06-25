// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelSnapshot.Environment {
    public init() {
        self.init(connectionStatus: .disconnected, dataCount: DataCount(), lastErrorCode: nil)
    }

    public func with(connectionStatus: ConnectionStatus) -> Self {
        Self(connectionStatus: connectionStatus, dataCount: dataCount, lastErrorCode: lastErrorCode)
    }

    public func with(dataCount: DataCount) -> Self {
        Self(connectionStatus: connectionStatus, dataCount: dataCount, lastErrorCode: lastErrorCode)
    }

    public func with(lastErrorCode: String) -> Self {
        Self(connectionStatus: connectionStatus, dataCount: dataCount, lastErrorCode: lastErrorCode)
    }

    public func with(lastErrorCode: PartoutError.Code) -> Self {
        with(lastErrorCode: lastErrorCode.rawValue)
    }
}

extension TunnelSnapshot {
    public init(id: Profile.ID, isEnabled: Bool, status: TunnelStatus, onDemand: Bool, environment: Environment? = nil) {
        self.init(environment: environment, id: id, isEnabled: isEnabled, onDemand: onDemand, status: status)
    }

    public func with(environment: Environment?) -> Self {
        Self(id: id, isEnabled: isEnabled, status: status, onDemand: onDemand, environment: environment)
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

extension TunnelEnvironmentReader {
    public var snapshot: TunnelSnapshot.Environment {
        let connectionStatus = environmentValue(forKey: TunnelEnvironmentKeys.connectionStatus)
        let dataCount = environmentValue(forKey: TunnelEnvironmentKeys.dataCount)
        let lastError = environmentValue(forKey: TunnelEnvironmentKeys.lastErrorCode)
        return TunnelSnapshot.Environment(
            connectionStatus: connectionStatus ?? .disconnected,
            dataCount: dataCount ?? DataCount(),
            lastErrorCode: lastError
        )
    }
}
