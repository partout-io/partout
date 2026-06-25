// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


/// Container of all WireGuard entities.
public enum WireGuard {
}

extension WireGuard {
    /// A Base64-encoded key.
    public struct Key: Hashable, Codable, RawRepresentable, Sendable {
        public let rawValue: String
    }

    /// The parameters of the local interface.
    public struct LocalInterface: Hashable, Codable, Sendable {
        public let privateKey: Key
        public let addresses: [Subnet]
        public let dns: DNSModule?
        public let mtu: UInt16?

        public init(privateKey: Key, addresses: [Subnet], dns: DNSModule?, mtu: UInt16?) {
            self.privateKey = privateKey
            self.addresses = addresses
            self.dns = dns
            self.mtu = mtu
        }
    }

    /// The parameters of the remote interface.
    public struct RemoteInterface: Hashable, Codable, Sendable {
        public let publicKey: Key
        public let preSharedKey: Key?
        public let endpoint: Endpoint?
        public let allowedIPs: [Subnet]
        public let keepAlive: UInt16?

        public init(publicKey: Key, preSharedKey: Key?, endpoint: Endpoint?, allowedIPs: [Subnet], keepAlive: UInt16?) {
            self.publicKey = publicKey
            self.preSharedKey = preSharedKey
            self.endpoint = endpoint
            self.allowedIPs = allowedIPs
            self.keepAlive = keepAlive
        }
    }

    /// Represents a WireGuard configuration.
    public struct Configuration: Hashable, Codable, Sendable {
        public let interface: LocalInterface
        public let peers: [RemoteInterface]

        public init(interface: LocalInterface, peers: [RemoteInterface]) {
            self.interface = interface
            self.peers = peers
        }
    }
}

/// A connection module providing a WireGuard connection.
public struct WireGuardModule: Hashable, Codable, Sendable {
    public let id: UniqueID
    public let configuration: WireGuard.Configuration?

    public init(id: UniqueID, configuration: WireGuard.Configuration?) {
        self.id = id
        self.configuration = configuration
    }
}
