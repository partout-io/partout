// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ModuleType {
    public static let httpProxy = ModuleType("HTTPProxy")
}

/// HTTP proxy settings.
public struct HTTPProxyModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.httpProxy, HTTPProxyModule.self)

    public let id: UniqueID

    public let proxy: Endpoint?

    public let secureProxy: Endpoint?

    public let pacURL: URL?

    public let bypassDomains: [Address]

    fileprivate init(
        id: UniqueID,
        proxy: Endpoint?,
        secureProxy: Endpoint?,
        pacURL: URL?,
        bypassDomains: [Address]
    ) {
        self.id = id
        self.proxy = proxy
        self.secureProxy = secureProxy
        self.pacURL = pacURL
        self.bypassDomains = bypassDomains
    }

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
                    throw PartoutError.invalidFields(["address": address])
                }
                proxy = Endpoint(addressObject, port)
            }
            if !secureAddress.isEmpty, securePort > 0 {
                guard let secureAddressObject = Address(rawValue: secureAddress),
                      secureAddressObject.isIPAddress else {
                    throw PartoutError.invalidFields(["secureAddress": secureAddress])
                }
                secureProxy = Endpoint(secureAddressObject, securePort)
            }
            if !pacURLString.isEmpty {
                pacURL = URL(string: pacURLString)
                guard pacURL != nil else {
                    throw PartoutError.invalidFields(["pacURLString": pacURLString])
                }
            }
            let validBypassDomains = try bypassDomains.map {
                guard let addr = Address(rawValue: $0), !addr.isIPAddress else {
                    throw PartoutError.invalidFields(["bypassDomain": $0])
                }
                return addr
            }
            return HTTPProxyModule(
                id: id,
                proxy: proxy,
                secureProxy: secureProxy,
                pacURL: pacURL,
                bypassDomains: validBypassDomains
            )
        }
    }
}
