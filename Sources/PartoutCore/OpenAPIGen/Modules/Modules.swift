// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


/// A type-erased ``Module`` for encoding external implementations.
public struct CustomModule: Hashable, Codable {
    public let innerType: ModuleType
    public let json: JSON

    public init(innerType: ModuleType, json: JSON) {
        self.innerType = innerType
        self.json = json
    }
}

/// The protocol used in DNS servers.
public enum DNSProtocol: String, Hashable, Codable, Sendable {
    case cleartext
    case https
    case tls
}

/// DNS settings.
public struct DNSModule: Hashable, Codable, Sendable {
    public enum ProtocolType: Hashable, Codable, Sendable {
        case cleartext
        case https(url: URL)
        case tls(hostname: String)
    }

    public enum DomainPolicy: String, Hashable, Codable, Sendable {
        case match
        case matchAndSearch
    }

    public let id: UniqueID
    public let protocolType: ProtocolType
    public let servers: [Address]
    public let domainName: Address?
    public let searchDomains: [Address]?
    public let inheritsVPN: Bool?
    public let domainPolicy: DomainPolicy?
    public let routesThroughVPN: Bool?

    public init(
        id: UniqueID,
        protocolType: ProtocolType,
        servers: [Address],
        domainName: Address?,
        searchDomains: [Address]?,
        inheritsVPN: Bool?,
        domainPolicy: DomainPolicy?,
        routesThroughVPN: Bool?
    ) {
        self.id = id
        self.protocolType = protocolType
        self.servers = servers
        self.domainName = domainName
        self.searchDomains = searchDomains
        self.inheritsVPN = inheritsVPN
        self.domainPolicy = domainPolicy
        self.routesThroughVPN = routesThroughVPN
    }
}

/// HTTP proxy settings.
public struct HTTPProxyModule: Hashable, Codable, Sendable {
    public let id: UniqueID
    public let proxy: Endpoint?
    public let secureProxy: Endpoint?
    public let pacURL: URL?
    public let bypassDomains: [Address]

    public init(id: UniqueID, proxy: Endpoint?, secureProxy: Endpoint?, pacURL: URL?, bypassDomains: [Address]) {
        self.id = id
        self.proxy = proxy
        self.secureProxy = secureProxy
        self.pacURL = pacURL
        self.bypassDomains = bypassDomains
    }
}

/// IP and routes.
public struct IPModule: Hashable, Codable, Sendable {
    public let id: UniqueID
    public let ipv4: IPSettings?
    public let ipv6: IPSettings?
    public let mtu: Int?

    public init(id: UniqueID, ipv4: IPSettings?, ipv6: IPSettings?, mtu: Int?) {
        self.id = id
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.mtu = mtu
    }
}

/// On-demand settings.
public struct OnDemandModule: Hashable, Codable, Sendable {
    public enum Policy: String, Codable, Sendable {
        case any
        case including
        case excluding
    }

    public enum OtherNetwork: String, Codable, Sendable {
        case mobile
        case ethernet
    }

    public let id: UniqueID
    public let policy: Policy
    public let withSSIDs: [String: Bool]
    public let withOtherNetworks: Set<OtherNetwork>

    public init(id: UniqueID, policy: Policy, withSSIDs: [String: Bool], withOtherNetworks: Set<OtherNetwork>) {
        self.id = id
        self.policy = policy
        self.withSSIDs = withSSIDs
        self.withOtherNetworks = withOtherNetworks
    }
}
