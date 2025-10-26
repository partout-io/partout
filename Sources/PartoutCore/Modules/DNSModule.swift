// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension ModuleType {
    public static let dns = ModuleType("DNS")
}

/// DNS settings.
public struct DNSModule: Module, BuildableType, Hashable, Codable {
    public enum ProtocolType: Hashable, Codable, Sendable {
        case cleartext

        case https(url: URL)

        case tls(hostname: String)
    }

    public static let moduleHandler = ModuleHandler(.dns, DNSModule.self)

    public let id: UniqueID

    public let protocolType: ProtocolType

    public let servers: [Address]

    public let domainName: Address?

    public let searchDomains: [Address]?

    public let routesThroughVPN: Bool?

    fileprivate init(
        id: UniqueID,
        protocolType: ProtocolType,
        servers: [Address],
        domainName: Address?,
        searchDomains: [Address]?,
        routesThroughVPN: Bool?
    ) {
        self.id = id
        self.protocolType = protocolType
        self.servers = servers
        self.domainName = domainName
        self.searchDomains = searchDomains
        self.routesThroughVPN = routesThroughVPN
    }

    public func builder() -> Builder {
        var builder = Builder(
            id: id,
            servers: servers.map(\.rawValue)
        )
        switch protocolType {
        case .cleartext:
            break

        case .https(let url):
            builder.protocolType = .https
            builder.dohURL = url.absoluteString

        case .tls(let hostname):
            builder.protocolType = .tls
            builder.dotHostname = hostname
        }
        builder.domainName = domainName?.rawValue
        builder.searchDomains = searchDomains?.map(\.rawValue)
        builder.routesThroughVPN = routesThroughVPN
        return builder
    }
}

extension DNSModule {
    public struct Builder: ModuleBuilder, Hashable {
        public let id: UniqueID

        public var protocolType: DNSProtocol

        public var servers: [String]

        public var dohURL: String

        public var dotHostname: String

        public var domainName: String?

        public var searchDomains: [String]?

        public var routesThroughVPN: Bool?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            protocolType: DNSProtocol = .cleartext,
            servers: [String] = [],
            dohURL: String = "",
            dotHostname: String = "",
            domainName: String? = nil,
            searchDomains: [String]? = nil,
            routesThroughVPN: Bool? = nil
        ) {
            self.id = id
            self.protocolType = protocolType
            self.servers = servers
            self.dohURL = dohURL
            self.dotHostname = dotHostname
            self.domainName = domainName
            self.searchDomains = searchDomains
            self.routesThroughVPN = routesThroughVPN
        }

        public func build() throws -> DNSModule {
            let validServers = try servers.compactMap {
                guard !$0.isEmpty else {
                    return nil as Address?
                }
                guard let addr = Address(rawValue: $0), addr.isIPAddress else {
                    throw PartoutError.invalidFields(["servers": $0])
                }
                return addr
            }
            let validDomainName = try domainName.flatMap {
                guard !$0.isEmpty else {
                    return nil as Address?
                }
                guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                    throw PartoutError.invalidFields(["domainName": $0])
                }
                return addr
            }
            let validSearchDomains = try searchDomains?.compactMap {
                guard !$0.isEmpty else {
                    return nil as Address?
                }
                guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                    throw PartoutError.invalidFields(["searchDomains": $0])
                }
                return addr
            }

            let validProtocolType: ProtocolType
            switch protocolType {
            case .cleartext:
                validProtocolType = .cleartext
            case .https:
                guard !dohURL.isEmpty,
                      let url = URL(string: dohURL),
                      url.scheme == "https" else {
                    throw PartoutError.invalidFields(["dohURL": dohURL])
                }
                validProtocolType = .https(url: url)
            case .tls:
                guard !dotHostname.isEmpty else {
                    throw PartoutError.invalidFields(["dotHostname": nil])
                }
                validProtocolType = .tls(hostname: dotHostname)
            }
            return DNSModule(
                id: id,
                protocolType: validProtocolType,
                servers: validServers,
                domainName: validDomainName,
                searchDomains: validSearchDomains,
                routesThroughVPN: routesThroughVPN
            )
        }
    }
}

extension DNSModule.ProtocolType {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let map: [String: [String: String]]
        let isSensitive = encoder.shouldEncodeSensitiveData
        switch self {
        case .cleartext:
            map = ["cleartext": [:]]

        case .https(let url):
            map = ["https": ["url": url.debugDescription(withSensitiveData: isSensitive)]]

        case .tls(let hostname):
            map = ["tls": ["hostname": hostname.debugDescription(withSensitiveData: isSensitive)]]
        }
        try container.encode(map)
    }
}
