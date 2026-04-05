// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuard {

    /// Represents a WireGuard configuration.
    public struct Configuration: BuildableType, Hashable, Codable, Sendable {

        /// The local interface.
        public let interface: LocalInterface

        /// The peers.
        public let peers: [RemoteInterface]

        public init(interface: LocalInterface, peers: [RemoteInterface]) {
            self.interface = interface
            self.peers = peers
        }

        public func builder() -> Builder {
            Builder(
                interface: interface.builder(),
                peers: peers.map {
                    $0.builder()
                }
            )
        }
    }
}

extension WireGuard.Configuration: SerializableConfiguration {
    public func serialized() throws -> String {
        asWgQuickConfig()
    }
}

extension WireGuard.Configuration {
    public struct Builder: BuilderType, Hashable, Sendable {
        public var interface: WireGuard.LocalInterface.Builder

        public var peers: [WireGuard.RemoteInterface.Builder]

        public init(privateKey: String) {
            self.init(
                interface: WireGuard.LocalInterface.Builder(privateKey: privateKey),
                peers: []
            )
        }

        public init(keyGenerator: WireGuardKeyGenerator) {
            self.init(
                interface: WireGuard.LocalInterface.Builder(keyGenerator: keyGenerator),
                peers: []
            )
        }

        public init(interface: WireGuard.LocalInterface.Builder, peers: [WireGuard.RemoteInterface.Builder]) {
            self.interface = interface
            self.peers = peers
        }

        public func build() throws -> WireGuard.Configuration {
            guard !peers.isEmpty else {
                throw PartoutError(.WireGuard.emptyPeers)
            }
            return WireGuard.Configuration(
                interface: try interface.build(),
                peers: try peers.map {
                    try $0.build()
                }
            )
        }
    }
}

// MARK: - Helpers

extension WireGuard.Configuration {
    public func withModules(from profile: Profile) throws -> Self {
        var newBuilder = builder()

        // Add IPModule.*.includedRoutes to AllowedIPs
        profile.activeModules
            .compactMap {
                $0 as? IPModule
            }
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

        // If routesThroughVPN, add DNSModule.servers to AllowedIPs
        profile.activeModules
            .compactMap {
                $0 as? DNSModule
            }
            .filter {
                $0.routesThroughVPN == true
            }
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
