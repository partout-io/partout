// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension WireGuard {

    /// Represents a WireGuard configuration.
    public struct Configuration: BuildableType, Hashable, Codable, Sendable {

        /// The local interface.
        public let interface: LocalInterface

        /// The peers.
        public let peers: [RemoteInterface]

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

        public func tryBuild() throws -> WireGuard.Configuration {
            guard !peers.isEmpty else {
                throw PartoutError(.WireGuard.emptyPeers)
            }
            return WireGuard.Configuration(
                interface: try interface.tryBuild(),
                peers: try peers.map {
                    try $0.tryBuild()
                }
            )
        }
    }
}
