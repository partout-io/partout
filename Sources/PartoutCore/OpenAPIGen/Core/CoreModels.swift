// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


/// The status of a ``Connection``.
@frozen
public enum ConnectionStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// A pair of received/sent bytes count.
public struct DataCount: Hashable, Codable, Sendable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

/// Raw type univocally associated to each ``Module`` implementation.
public enum ModuleType: String, RawRepresentable, Identifiable, Hashable, Codable, Sendable {
    case Custom
    case DNS
    case HTTPProxy
    case IP
    case OnDemand
    case OpenVPN
    case Provider
    case WireGuard
    case Undefined
}

/// Advanced flags affecting the behavior of a ``Profile``.
public struct ProfileBehavior: Hashable, Codable, Sendable {
    public var disconnectsOnSleep: Bool
    public var includesAllNetworks: Bool?

    public init(disconnectsOnSleep: Bool, includesAllNetworks: Bool?) {
        self.disconnectsOnSleep = disconnectsOnSleep
        self.includesAllNetworks = includesAllNetworks
    }
}

/// Wrapper of a byte array with safe encoding capabilities.
public struct SecureData: Hashable, Codable, @unchecked Sendable {
    internal let innerData: [UInt8]

    public init(innerData: [UInt8]) {
        self.innerData = innerData
    }
}

/// Common options to give to ``TunnelController``.
public struct TunnelControllerOptions: Codable, Sendable {
    public var dnsFallbackServers: [String]
    public var logsSnapshots: Bool
    public var minDataCountDelta: UInt64

    public init(dnsFallbackServers: [String], logsSnapshots: Bool, minDataCountDelta: UInt64) {
        self.dnsFallbackServers = dnsFallbackServers
        self.logsSnapshots = logsSnapshots
        self.minDataCountDelta = minDataCountDelta
    }
}

/// The status of a ``Tunnel``.
@frozen
public enum TunnelStatus: String, Codable {
    case inactive
    case activating
    case active
    case deactivating
}

/// Returns a tunnel-specific snapshot of a ``Profile``.
public struct TunnelSnapshot: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Environment: Hashable, Codable, Sendable {
        public internal(set) var connectionStatus: ConnectionStatus
        public internal(set) var dataCount: DataCount
        public internal(set) var lastErrorCode: String?

        public init(
            connectionStatus: ConnectionStatus = .disconnected,
            dataCount: DataCount = DataCount(),
            lastErrorCode: String? = nil
        ) {
            self.connectionStatus = connectionStatus
            self.dataCount = dataCount
            self.lastErrorCode = lastErrorCode
        }
    }

    public let id: UniqueID
    public let isEnabled: Bool
    public let status: TunnelStatus
    public let onDemand: Bool
    public internal(set) var environment: Environment?

    public init(id: UniqueID, isEnabled: Bool, status: TunnelStatus, onDemand: Bool, environment: Environment? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.status = status
        self.onDemand = onDemand
        self.environment = environment
    }
}

/// Encodable wrapper for remote tunnel hand-off data.
public struct TunnelRemoteInfoWrapper: Codable, Sendable {
    public let profile: TaggedProfile
    public let options: TunnelControllerOptions
    public let originalModuleId: UniqueID
    public let address: Address?
    public let requiresVirtualDevice: Bool
    public let modules: [TaggedModule]?

    public init(
        profile: TaggedProfile,
        options: TunnelControllerOptions,
        originalModuleId: UniqueID,
        address: Address?,
        requiresVirtualDevice: Bool,
        modules: [TaggedModule]?
    ) {
        self.profile = profile
        self.options = options
        self.originalModuleId = originalModuleId
        self.address = address
        self.requiresVirtualDevice = requiresVirtualDevice
        self.modules = modules
    }
}
