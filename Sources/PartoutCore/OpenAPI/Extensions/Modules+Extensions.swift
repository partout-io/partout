// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension CustomModule: Module {
    public static let moduleType: ModuleType = .Custom

    public init(_ module: Module & Encodable) throws {
        self.init(
            innerType: module.moduleType,
            json: try JSON(encodable: module)
        )
    }
}

extension DNSProtocol {
    public static let fallback: DNSProtocol = .cleartext
}

extension DNSModule {
    public enum ProtocolType: Hashable, Codable, Sendable {
        case cleartext
        case https(url: URL)
        case tls(hostname: String)
    }
}

extension DNSModule: Module, BuildableType {
    public static let moduleType: ModuleType = .DNS

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
            domainPolicy: DomainPolicy? = nil,
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
            let validServers: [Address]
            let validDomains: [Address]?
            let validProtocolType: DNSModule.ProtocolType
            if inheritsVPN != true {
                validServers = try servers.compactMap {
                    guard !$0.isEmpty else {
                        return nil as Address?
                    }
                    guard let addr = Address(rawValue: $0), addr.isIPAddress else {
                        throw PartoutError.invalidField(.DNS.nonIPServers)
                    }
                    return addr
                }
                validDomains = try domains?.compactMap {
                    guard !$0.isEmpty else {
                        return nil as Address?
                    }
                    guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                        throw PartoutError.invalidField(.DNS.ipDomains)
                    }
                    return addr
                }
                switch protocolType {
                case .cleartext:
                    guard !validServers.isEmpty else {
                        throw PartoutError.invalidField(.DNS.emptyServers)
                    }
                    validProtocolType = .cleartext
                case .https:
                    guard !dohURL.isEmpty,
                          let url = URL(string: dohURL),
                          url.scheme == "https" else {
                        throw PartoutError.invalidField(.DNS.invalidDoHURL)
                    }
                    validProtocolType = .https(url: url)
                case .tls:
                    guard !dotHostname.isEmpty else {
                        throw PartoutError.invalidField(.DNS.emptyDoTHostname)
                    }
                    validProtocolType = .tls(hostname: dotHostname)
                }
            } else {
                validServers = []
                validDomains = nil
                validProtocolType = .cleartext
            }
            return DNSModule(
                domainName: isFirstDomainPrimary ? validDomains?.first : nil,
                domainPolicy: domainPolicy,
                id: id,
                inheritsVPN: inheritsVPN,
                protocolType: validProtocolType,
                routesThroughVPN: routesThroughVPN,
                searchDomains: validDomains,
                servers: validServers
            )
        }
    }
}

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

extension PartoutError.ModuleField {
    public enum DNS {
        private static let root = "DNS"
        public static let emptyServers = PartoutError.ModuleField("\(root).emptyServers")
        public static let nonIPServers = PartoutError.ModuleField("\(root).nonIPServers")
        public static let ipDomains = PartoutError.ModuleField("\(root).ipDomains")
        public static let invalidDoHURL = PartoutError.ModuleField("\(root).invalidDoHURL")
        public static let emptyDoTHostname = PartoutError.ModuleField("\(root).emptyDoTHostname")
    }
}

extension HTTPProxyModule: Module, BuildableType {
    public static let moduleType: ModuleType = .HTTPProxy

    public func builder() -> Builder {
        Builder(
            id: id,
            address: proxy?.address.rawValue ?? "",
            port: proxy?.port ?? 0,
            secureAddress: secureProxy?.address.rawValue ?? "",
            securePort: secureProxy?.port ?? 0,
            pacURLString: pacURL?.absoluteString ?? "",
            bypassDomains: bypassDomains.map(\.rawValue)
        )
    }
}

extension HTTPProxyModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var address: String
        public var port: UInt16
        public var secureAddress: String
        public var securePort: UInt16
        public var pacURLString: String
        public var bypassDomains: [String]

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            address: String = "",
            port: UInt16 = 0,
            secureAddress: String = "",
            securePort: UInt16 = 0,
            pacURLString: String = "",
            bypassDomains: [String] = []
        ) {
            self.id = id
            self.address = address
            self.port = port
            self.secureAddress = secureAddress
            self.securePort = securePort
            self.pacURLString = pacURLString
            self.bypassDomains = bypassDomains
        }

        public func build() throws -> HTTPProxyModule {
            var proxy: Endpoint?
            var secureProxy: Endpoint?
            var pacURL: URL?
            if !address.isEmpty, port > 0 {
                guard let addressObject = Address(rawValue: address),
                      addressObject.isIPAddress else {
                    throw PartoutError.invalidField(.HTTPProxy.address)
                }
                proxy = Endpoint(addressObject, port)
            }
            if !secureAddress.isEmpty, securePort > 0 {
                guard let secureAddressObject = Address(rawValue: secureAddress),
                      secureAddressObject.isIPAddress else {
                    throw PartoutError.invalidField(.HTTPProxy.secureAddress)
                }
                secureProxy = Endpoint(secureAddressObject, securePort)
            }
            if !pacURLString.isEmpty {
                pacURL = URL(string: pacURLString)
                guard pacURL != nil else {
                    throw PartoutError.invalidField(.HTTPProxy.pacURLString)
                }
            }
            let validBypassDomains = try bypassDomains.map {
                guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                    throw PartoutError.invalidField(.HTTPProxy.bypassDomains)
                }
                return addr
            }
            return HTTPProxyModule(
                bypassDomains: validBypassDomains,
                id: id,
                pacURL: pacURL,
                proxy: proxy,
                secureProxy: secureProxy
            )
        }
    }
}

extension PartoutError.ModuleField {
    public enum HTTPProxy {
        private static let root = "HTTPProxy"
        public static let address = PartoutError.ModuleField("\(root).address")
        public static let secureAddress = PartoutError.ModuleField("\(root).secureAddress")
        public static let pacURLString = PartoutError.ModuleField("\(root).pacURLString")
        public static let bypassDomains = PartoutError.ModuleField("\(root).bypassDomains")
    }
}

extension IPModule: Module, BuildableType {
    public static let moduleType: ModuleType = .IP

    public func builder() -> Builder {
        Builder(id: id, ipv4: ipv4, ipv6: ipv6, mtu: mtu)
    }
}

extension IPModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var ipv4: IPSettings?
        public var ipv6: IPSettings?
        public var mtu: Int?

        public static func empty() -> Self {
            self.init()
        }

        public init(id: UniqueID = UniqueID(), ipv4: IPSettings? = nil, ipv6: IPSettings? = nil, mtu: Int? = nil) {
            self.id = id
            self.ipv4 = ipv4
            self.ipv6 = ipv6
            self.mtu = mtu
        }

        public func build() -> IPModule {
            IPModule(id: id, ipv4: ipv4?.nilIfEmpty, ipv6: ipv6?.nilIfEmpty, mtu: mtu)
        }
    }
}

extension OnDemandModule: Module, BuildableType {
    public static let moduleType: ModuleType = .OnDemand

    public func builder() -> Builder {
        var builder = Builder(id: id)
        builder.policy = policy
        builder.withSSIDs = withSSIDs
        builder.withOtherNetworks = withOtherNetworks
        return builder
    }
}

extension OnDemandModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var policy: Policy
        public var withSSIDs: [String: Bool]
        public var withOtherNetworks: Set<OtherNetwork>

        public static func empty() -> Self {
            self.init()
        }

        public init(id: UniqueID = UniqueID()) {
            self.id = id
            policy = .any
            withSSIDs = [:]
            withOtherNetworks = []
        }

        public func build() -> OnDemandModule {
            OnDemandModule(
                id: id,
                policy: policy,
                withOtherNetworks: withOtherNetworks,
                withSSIDs: withSSIDs
            )
        }
    }
}

extension OnDemandModule {
    public var withMobileNetwork: Bool {
        withOtherNetworks.contains(.mobile)
    }

    public var withEthernetNetwork: Bool {
        withOtherNetworks.contains(.ethernet)
    }
}

extension OnDemandModule.Builder {
    public var withMobileNetwork: Bool {
        get {
            withOtherNetworks.contains(.mobile)
        }
        set {
            if newValue {
                withOtherNetworks.insert(.mobile)
            } else {
                withOtherNetworks.remove(.mobile)
            }
        }
    }

    public var withEthernetNetwork: Bool {
        get {
            withOtherNetworks.contains(.ethernet)
        }
        set {
            if newValue {
                withOtherNetworks.insert(.ethernet)
            } else {
                withOtherNetworks.remove(.ethernet)
            }
        }
    }
}
