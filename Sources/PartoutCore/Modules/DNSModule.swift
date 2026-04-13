// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// DNS settings.
public struct DNSModule: Module, BuildableType, Hashable, Codable {
    public enum ProtocolType: Hashable, Codable, Sendable {
        case cleartext

        case https(url: URL)

        case tls(hostname: String)
    }

    public enum DomainPolicy: String, Hashable, Codable, Sendable {
        case match
    }

    public static let moduleType = ModuleType("DNS")

    public let id: UniqueID

    public let protocolType: ProtocolType

    public let servers: [Address]

    public let domainName: Address?

    public let searchDomains: [Address]?

    public let inheritsVPN: Bool?

    public let domainPolicy: DomainPolicy?

    public let routesThroughVPN: Bool?

    fileprivate init(
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
        if let domainName {
            builder.isFirstDomainPrimary = true
            if let searchDomains {
                if domainName == searchDomains.first {
                    builder.domains = searchDomains.map(\.rawValue)
                } else {
                    builder.domains = [domainName.rawValue] + searchDomains.map(\.rawValue)
                }
            } else {
                builder.domains = [domainName.rawValue]
            }
        } else if let searchDomains {
            builder.isFirstDomainPrimary = false
            builder.domains = searchDomains.map(\.rawValue)
        }
        builder.inheritsVPN = inheritsVPN ?? false
        builder.domainPolicy = domainPolicy
        builder.routesThroughVPN = routesThroughVPN
        return builder
    }
}

extension DNSModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID

        public var protocolType: DNSProtocol

        public var servers: [String]

        public var dohURL: String

        public var dotHostname: String

        public var domains: [String]?

        public var inheritsVPN: Bool

        public var domainPolicy: DomainPolicy?

        public var isFirstDomainPrimary: Bool

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
            domains: [String]? = nil,
            inheritsVPN: Bool = false,
            domainPolicy: DomainPolicy? = .match,
            isFirstDomainPrimary: Bool = false,
            routesThroughVPN: Bool? = nil
        ) {
            self.id = id
            self.protocolType = protocolType
            self.servers = servers
            self.dohURL = dohURL
            self.dotHostname = dotHostname
            self.domains = domains
            self.inheritsVPN = inheritsVPN
            self.domainPolicy = domainPolicy
            self.isFirstDomainPrimary = isFirstDomainPrimary
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
            let validDomains = try domains?.compactMap {
                guard !$0.isEmpty else {
                    return nil as Address?
                }
                guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                    throw PartoutError.invalidFields(["domains": $0])
                }
                return addr
            }
            let validProtocolType: ProtocolType
            switch protocolType {
            case .cleartext:
                guard !validServers.isEmpty else {
                    throw PartoutError.invalidFields(["servers": nil])
                }
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
                domainName: isFirstDomainPrimary ? validDomains?.first : nil,
                searchDomains: validDomains,
                inheritsVPN: inheritsVPN,
                domainPolicy: domainPolicy,
                routesThroughVPN: routesThroughVPN
            )
        }
    }
}

// MARK: - Custom Codable

extension DNSModule.ProtocolType {
    typealias Discriminator = DNSProtocol

    enum CodingKeys: String, CodingKey {
        case type
        case url
        case hostname
    }

    enum LegacyCodingKeys: String, CodingKey {
        case cleartext
        case https
        case tls
    }

    enum LegacyHTTPSCodingKeys: String, CodingKey {
        case url
    }

    enum LegacyTLSCodingKeys: String, CodingKey {
        case hostname
    }

    public init(from decoder: any Decoder) throws {
        if let value = try Self.fromTagged(decoder: decoder) {
            self = value
            return
        }
        self = try Self.fromLegacy(decoder: decoder)
    }

    private static func fromTagged(decoder: any Decoder) throws -> Self? {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let discriminator = try container.decodeIfPresent(
            Discriminator.self,
            forKey: .type
        ) else {
            return nil
        }
        switch discriminator {
        case .cleartext:
            return .cleartext
        case .https:
            let url = try container.decode(URL.self, forKey: .url)
            return .https(url: url)
        case .tls:
            let hostname = try container.decode(String.self, forKey: .hostname)
            return .tls(hostname: hostname)
        }
    }

    private static func fromLegacy(decoder: any Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if container.contains(.cleartext) {
            return .cleartext
        }
        if container.contains(.https) {
            let map = try container.superDecoder(forKey: .https)
            let sub = try map.container(keyedBy: LegacyHTTPSCodingKeys.self)
            let url = try sub.decode(URL.self, forKey: .url)
            return .https(url: url)
        }
        if container.contains(.tls) {
            let map = try container.superDecoder(forKey: .tls)
            let sub = try map.container(keyedBy: LegacyTLSCodingKeys.self)
            let hostname = try sub.decode(String.self, forKey: .hostname)
            return .tls(hostname: hostname)
        }
        throw PartoutError(.decoding)
    }

    public func encode(to encoder: any Encoder) throws {
        // Legacy Swift encoding (incompatible with cross)
        if encoder.userInfo.usesLegacySwiftEncoding {
            var container = encoder.singleValueContainer()
            let map: [String: [String: String]]
            let isSensitive = encoder.shouldEncodeSensitiveData
            switch self {
            case .cleartext:
                map = [Discriminator.cleartext.rawValue: [:]]
            case .https(let url):
                map = [
                    Discriminator.https.rawValue: [
                        LegacyHTTPSCodingKeys.url.rawValue: url.debugDescription(withSensitiveData: isSensitive)
                    ]
                ]
            case .tls(let hostname):
                map = [
                    Discriminator.tls.rawValue: [
                        LegacyTLSCodingKeys.hostname.rawValue: hostname.debugDescription(withSensitiveData: isSensitive)
                    ]
                ]
            }
            try container.encode(map)
            return
        }

        // Tagged union (cross friendly)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let isSensitive = encoder.shouldEncodeSensitiveData
        let discriminator: Discriminator
        var url: String?
        var hostname: String?
        switch self {
        case .cleartext:
            discriminator = .cleartext
        case .https(let arg):
            discriminator = .https
            url = arg.debugDescription(withSensitiveData: isSensitive)
        case .tls(let arg):
            discriminator = .tls
            hostname = arg.debugDescription(withSensitiveData: isSensitive)
        }
        try container.encode(discriminator, forKey: .type)
        if let url {
            try container.encode(url, forKey: .url)
        }
        if let hostname {
            try container.encode(hostname, forKey: .hostname)
        }
    }
}
