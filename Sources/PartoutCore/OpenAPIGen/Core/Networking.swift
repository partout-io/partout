// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


/// A hostname or IP address.
@frozen
public enum Address: Hashable, Codable, Sendable {
    case ip(String, _ family: Family)
    case hostname(String)

    @frozen
    public enum Family: String, Sendable {
        case v4
        case v6
    }
}

/// A socket type between UDP and TCP.
@frozen
public enum SocketType: String, Codable, Sendable {
    case udp = "UDP"
    case tcp = "TCP"
}

/// A socket type with optional info about the IP endpoint.
@frozen
public enum IPSocketType: String, Codable, Sendable {
    case udp = "UDP"
    case tcp = "TCP"
    case udp4 = "UDP4"
    case tcp4 = "TCP4"
    case udp6 = "UDP6"
    case tcp6 = "TCP6"
}

/// Defines the communication protocol of an endpoint.
public struct EndpointProtocol: Hashable, Sendable {
    public let socketType: IPSocketType
    public let port: UInt16

    public init(socketType: IPSocketType, port: UInt16) {
        self.socketType = socketType
        self.port = port
    }
}

/// Represents an endpoint.
public struct Endpoint: Hashable, Codable, Sendable {
    public let address: Address
    public let port: UInt16

    public init(address: Address, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// Aggregates an address and an ``EndpointProtocol``.
public struct ExtendedEndpoint: Hashable, Codable, Sendable {
    public let address: Address
    public let proto: EndpointProtocol

    public init(address: Address, proto: EndpointProtocol) {
        self.address = address
        self.proto = proto
    }
}

/// An IPv4/v6 subnet.
public struct Subnet: Hashable, Codable, Sendable {
    public let address: Address
    public let prefixLength: Int

    public init(address: Address, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }
}

/// Represents a route in the routing table.
public struct Route: Hashable, Codable, Sendable {
    public let destination: Subnet?
    public let gateway: Address?

    public init(destination: Subnet?, gateway: Address?) {
        self.destination = destination
        self.gateway = gateway
    }
}

/// IP settings and routes.
public struct IPSettings: Hashable, Codable, Sendable {
    public internal(set) var subnets: [Subnet]
    public internal(set) var includedRoutes: [Route]
    public internal(set) var excludedRoutes: [Route]

    public init(subnets: [Subnet], includedRoutes: [Route], excludedRoutes: [Route]) {
        self.subnets = subnets
        self.includedRoutes = includedRoutes
        self.excludedRoutes = excludedRoutes
    }
}
