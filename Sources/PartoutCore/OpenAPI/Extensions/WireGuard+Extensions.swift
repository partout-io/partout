// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension LoggerCategory {
    public static let wireguard = Self(rawValue: "wireguard")
}

extension WireGuard {
    /// A Base64-encoded key.
    public struct Key: Hashable, Codable, RawRepresentable, Sendable {
        public let rawValue: String

        public init?(rawValue: String) {
            guard Data(base64Encoded: rawValue) != nil else {
                return nil
            }
            self.rawValue = rawValue
        }
    }
}

extension WireGuard.Key: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? rawValue : PartoutLogger.redactedValue
    }
}

extension WireGuard.LocalInterface: BuildableType {
    public func builder() -> Builder {
        var copy = Builder(privateKey: privateKey.rawValue)
        copy.addresses = addresses.map(\.rawValue)
        copy.dns = dns?.builder()
        copy.mtu = mtu
        return copy
    }
}

extension WireGuard.LocalInterface {
    public struct Builder: BuilderType, Hashable, Sendable {
        public var privateKey: String
        public var addresses: [String]
        public var dns: DNSModule.Builder?
        public var mtu: UInt16?

        public init(privateKey: String) {
            self.privateKey = privateKey
            dns = nil
            addresses = []
        }

        public func build() throws -> WireGuard.LocalInterface {
            guard let validPrivateKey = WireGuard.Key(rawValue: privateKey) else {
                throw PartoutError.invalidField(.WireGuard.privateKey)
            }
            let validAddresses = try addresses.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.addresses)
                }
                return addr
            }
            return WireGuard.LocalInterface(
                addresses: validAddresses,
                dns: try dns?.build(),
                mtu: mtu,
                privateKey: validPrivateKey
            )
        }
    }
}

extension PartoutError.ModuleField {
    public enum WireGuard {
        private static let root = "WireGuard"
        public static let privateKey = PartoutError.ModuleField("\(root).privateKey")
        public static let addresses = PartoutError.ModuleField("\(root).addresses")
    }
}

extension WireGuard.RemoteInterface: BuildableType {
    public func builder() -> Builder {
        var copy = Builder(publicKey: publicKey.rawValue)
        copy.preSharedKey = preSharedKey?.rawValue
        copy.endpoint = endpoint?.rawValue
        copy.allowedIPs = allowedIPs.map(\.rawValue)
        copy.keepAlive = keepAlive
        return copy
    }
}

extension WireGuard.RemoteInterface {
    public struct Builder: BuilderType, Hashable, Sendable {
        public let publicKey: String
        public var preSharedKey: String?
        public var endpoint: String?
        public var allowedIPs: [String]
        public var keepAlive: UInt16?

        public init(publicKey: String) {
            self.publicKey = publicKey
            allowedIPs = []
        }

        public func build() throws -> WireGuard.RemoteInterface {
            guard let validPublicKey = WireGuard.Key(rawValue: publicKey) else {
                throw PartoutError.invalidField(.WireGuard.publicKey)
            }
            let validPreSharedKey: WireGuard.Key? = try preSharedKey.flatMap {
                guard !$0.isEmpty else { return nil }
                guard let key = WireGuard.Key(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.preSharedKey)
                }
                return key
            }
            let validEndpoint = try endpoint.map {
                guard let ep = Endpoint(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.endpoint)
                }
                return ep
            }
            let validAllowedIPs = try allowedIPs.map {
                guard let addr = Subnet(rawValue: $0) else {
                    throw PartoutError.invalidField(.WireGuard.allowedIPs)
                }
                return addr
            }
            return WireGuard.RemoteInterface(
                allowedIPs: validAllowedIPs,
                endpoint: validEndpoint,
                keepAlive: keepAlive,
                preSharedKey: validPreSharedKey,
                publicKey: validPublicKey
            )
        }
    }
}

extension WireGuard.RemoteInterface.Builder {
    public mutating func addAllowedIP(_ allowedIP: String) {
        allowedIPs.append(allowedIP)
    }

    public mutating func removeAllowedIP(_ allowedIP: String) {
        allowedIPs.removeAll {
            $0 == allowedIP
        }
    }

    public mutating func addDefaultGatewayIPv4() {
        allowedIPs.append(Subnet.defaultGateway4.rawValue)
    }

    public mutating func addDefaultGatewayIPv6() {
        allowedIPs.append(Subnet.defaultGateway6.rawValue)
    }

    public mutating func removeDefaultGatewayIPv4() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway4.rawValue
        }
    }

    public mutating func removeDefaultGatewayIPv6() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway6.rawValue
        }
    }

    public mutating func removeDefaultGateways() {
        allowedIPs.removeAll {
            $0 == Subnet.defaultGateway4.rawValue || $0 == Subnet.defaultGateway6.rawValue
        }
    }
}

private extension Subnet {
    static let defaultGateway4: Subnet = {
        do {
            return try Subnet("0.0.0.0", 0)
        } catch {
            fatalError("Cannot build: \(error)")
        }
    }()

    static let defaultGateway6: Subnet = {
        do {
            return try Subnet("::/0", 0)
        } catch {
            fatalError("Cannot build: \(error)")
        }
    }()
}

extension PartoutError.ModuleField.WireGuard {
    public static let publicKey = PartoutError.ModuleField("WireGuard.publicKey")
    public static let preSharedKey = PartoutError.ModuleField("WireGuard.preSharedKey")
    public static let endpoint = PartoutError.ModuleField("WireGuard.endpoint")
    public static let allowedIPs = PartoutError.ModuleField("WireGuard.allowedIPs")
}

extension WireGuard.Configuration: BuildableType {
    public func builder() -> Builder {
        Builder(
            interface: interface.builder(),
            peers: peers.map { $0.builder() }
        )
    }
}

extension WireGuard.Configuration {
    public struct Builder: BuilderType, Hashable, Sendable {
        public var interface: WireGuard.LocalInterface.Builder
        public var peers: [WireGuard.RemoteInterface.Builder]

        public init(privateKey: String) {
            self.init(interface: WireGuard.LocalInterface.Builder(privateKey: privateKey), peers: [])
        }

        public init(interface: WireGuard.LocalInterface.Builder, peers: [WireGuard.RemoteInterface.Builder]) {
            self.interface = interface
            self.peers = peers
        }

        public func build() throws -> WireGuard.Configuration {
            guard !peers.isEmpty else {
                throw PartoutError(.wireGuardEmptyPeers)
            }
            return WireGuard.Configuration(
                interface: try interface.build(),
                peers: try peers.map { try $0.build() }
            )
        }
    }
}

extension WireGuard.Configuration {
    public func withModules(from profile: Profile) throws -> Self {
        var newBuilder = builder()

        profile.activeModules
            .compactMap { $0 as? IPModule }
            .forEach { ipModule in
                newBuilder.peers = newBuilder.peers
                    .map { oldPeer in
                        var peer = oldPeer
                        ipModule.ipv4?.includedRoutes.forEach { route in
                            peer.allowedIPs.append(route.destination?.rawValue ?? "0.0.0.0/0")
                        }
                        ipModule.ipv6?.includedRoutes.forEach { route in
                            peer.allowedIPs.append(route.destination?.rawValue ?? "::/0")
                        }
                        return peer
                    }
            }

        profile.activeModules
            .compactMap { $0 as? DNSModule }
            .filter { $0.routesThroughVPN == true }
            .forEach { dnsModule in
                newBuilder.peers = newBuilder.peers
                    .map { oldPeer in
                        var peer = oldPeer
                        dnsModule.servers.forEach {
                            switch $0 {
                            case .ip(let addr, let family):
                                switch family {
                                case .v4:
                                    peer.allowedIPs.append("\(addr)/32")
                                case .v6:
                                    peer.allowedIPs.append("\(addr)/128")
                                }
                            case .hostname:
                                break
                            }
                        }
                        return peer
                    }
            }

        return try newBuilder.build()
    }
}

extension WireGuardModule: Module, BuildableType {
    public static let moduleType: ModuleType = .WireGuard

    public func builder() -> Builder {
        Builder(id: id, configurationBuilder: configuration?.builder())
    }
}

extension WireGuardModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var configurationBuilder: WireGuard.Configuration.Builder?

        public static func empty() -> Self {
            self.init()
        }

        public init(id: UniqueID = UniqueID(), configurationBuilder: WireGuard.Configuration.Builder? = nil) {
            self.id = id
            self.configurationBuilder = configurationBuilder
        }

        public func build() throws -> WireGuardModule {
            guard let configurationBuilder else {
                throw PartoutError(.incompleteModule, self)
            }
            return WireGuardModule(configuration: try configurationBuilder.build(), id: id)
        }
    }
}
