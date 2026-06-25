// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Swift-specific extensions distilled from Sources/PartoutCore/OpenAPI.


internal import _PartoutPortable_C

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

extension DataCount {
    public static let zero = DataCount()

    public init(_ received: UInt64 = .zero, _ sent: UInt64 = .zero) {
        self.init(received: received, sent: sent)
    }

    public func adding(_ other: DataCount) -> Self {
        adding(other.received, other.sent)
    }

    public func adding(_ received: UInt64, _ sent: UInt64) -> Self {
        DataCount(self.received + received, self.sent + sent)
    }
}

extension DataCount: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{in=\(received), out=\(sent)}"
    }
}

extension ModuleType {
    public init(_ name: String) {
        let value = ModuleType(rawValue: name)
        self = value ?? .Undefined
    }

    public var id: String {
        rawValue
    }
}

extension ModuleType {
    private enum CodingKeys: CodingKey {
        case name
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let name = try container.decode(String.self)
            self.init(name)
        } catch {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .name)
            self.init(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ModuleType: CustomDebugStringConvertible {
    public var debugDescription: String {
        rawValue
    }
}

extension ProfileBehavior {
    public static let `default` = ProfileBehavior()

    public init() {
        self.init(disconnectsOnSleep: false, includesAllNetworks: false)
    }
}

extension SecureData {
    public init?(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        self.init(data)
    }

    public init(_ data: Data) {
        self.init(innerData: [UInt8](data))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        self.init(data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if encoder.shouldEncodeSensitiveData {
            try container.encode(Data(innerData))
        } else {
            try container.encode(PartoutLogger.redactedValue)
        }
    }
}

extension SecureData {
    public var count: Int {
        innerData.count
    }

    public func withOffset(_ offset: Int, count: Int) -> SecureData {
        SecureData(Data(innerData).subdata(offset: offset, count: count))
    }

    public func toData() -> Data {
        Data(innerData)
    }

    public func toHex() -> String {
        toData().toHex()
    }
}

extension SecureData: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? toHex() : PartoutLogger.redactedValue
    }
}

extension TunnelControllerOptions {
    public init() {
        self.init(dnsFallbackServers: [], logsSnapshots: false, minDataCountDelta: .zero)
    }
}

extension TunnelSnapshot.Environment {
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

    public func with(lastErrorCode: String) -> Self {
        var copy = self
        copy.lastErrorCode = lastErrorCode
        return copy
    }

    public func with(lastErrorCode: PartoutError.Code) -> Self {
        with(lastErrorCode: lastErrorCode.rawValue)
    }
}

extension TunnelSnapshot {
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

extension TunnelRemoteInfoWrapper {
    init(_ profile: Profile, options: TunnelControllerOptions, info: TunnelRemoteInfo) {
        self.init(
            profile: profile.asTaggedProfile,
            options: options,
            originalModuleId: info.originalModuleId,
            address: info.address,
            requiresVirtualDevice: info.requiresVirtualDevice,
            modules: info.modules?.compactMap(\.taggedModule)
        )
    }
}

extension TunnelRemoteInfo {
    func encodedAsJSON(_ profile: Profile, options: TunnelControllerOptions) throws -> String {
        let wrapped = TunnelRemoteInfoWrapper(profile, options: options, info: self)
        do {
            return try JSONEncoder.shared().encodeJSON(wrapped)
        } catch {
            throw PartoutError(error)
        }
    }
}

/// Helper for handling IP headers.
public struct IPHeader {
    private init() {
    }

    public static func protocolNumber(inPacket packet: Data) -> UInt32 {
        guard !packet.isEmpty else {
            return fallbackProtocolNumber
        }
        let version = (packet[0] & 0xf0) >> 4
        assert(version == ipV4Version || version == ipV6Version)
        return (version == ipV6Version) ? ipV6ProtocolNumber : ipV4ProtocolNumber
    }
}

private extension IPHeader {
    static let ipV4Version: UInt8 = 4
    static let ipV6Version: UInt8 = 6
    static let ipV4ProtocolNumber = UInt32(AF_INET)
    static let ipV6ProtocolNumber = UInt32(AF_INET6)
    static let fallbackProtocolNumber = ipV4ProtocolNumber
}
