// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// Encryption algorithm.
    public enum Cipher: String, Hashable, Codable, Sendable {

        // WARNING: must match OpenSSL algorithm names

        /// AES encryption with 128-bit key size and CBC.
        case aes128cbc = "AES-128-CBC"

        /// AES encryption with 192-bit key size and CBC.
        case aes192cbc = "AES-192-CBC"

        /// AES encryption with 256-bit key size and CBC.
        case aes256cbc = "AES-256-CBC"

        /// AES encryption with 128-bit key size and GCM.
        case aes128gcm = "AES-128-GCM"

        /// AES encryption with 192-bit key size and GCM.
        case aes192gcm = "AES-192-GCM"

        /// AES encryption with 256-bit key size and GCM.
        case aes256gcm = "AES-256-GCM"

        /// Returns the key size for this cipher.
        public var keySize: Int {
            switch self {
            case .aes128cbc, .aes128gcm:
                return 128

            case .aes192cbc, .aes192gcm:
                return 192

            case .aes256cbc, .aes256gcm:
                return 256
            }
        }

        /// Digest should be ignored when this is `true`.
        public var embedsDigest: Bool {
            return rawValue.hasSuffix("-GCM")
        }

        /// Returns a generic name for this cipher.
        public var genericName: String {
            return rawValue.hasSuffix("-GCM") ? "AES-GCM" : "AES-CBC"
        }
    }

    /// Message digest algorithm.
    public enum Digest: String, Hashable, Codable, Sendable {

        // WARNING: must match OpenSSL algorithm names

        /// SHA1 message digest.
        case sha1 = "SHA1"

        /// SHA224 message digest.
        case sha224 = "SHA224"

        /// SHA256 message digest.
        case sha256 = "SHA256"

        /// SHA256 message digest.
        case sha384 = "SHA384"

        /// SHA256 message digest.
        case sha512 = "SHA512"

        /// Returns a generic name for this digest.
        public var genericName: String {
            return "HMAC"
        }
    }

    /// Routing policy.
    public enum RoutingPolicy: String, Hashable, Codable, Sendable {

        /// All IPv4 traffic goes through the VPN.
        case IPv4

        /// All IPv6 traffic goes through the VPN.
        case IPv6

        /// Block LAN while connected.
        case blockLocal
    }

    /// Settings that can be pulled from server.
    public enum PullMask: String, Hashable, Codable, CaseIterable, Sendable {

        /// Routes and gateways.
        case routes

        /// DNS settings.
        case dns

        /// Proxy settings.
        case proxy
    }

    /// Verification target for `verify-x509-name`.
    public enum VerifyX509: String, Hashable, Codable, Sendable {
        case name
        case subject
    }
}

// MARK: - Configuration

extension OpenVPN {

    /// The immutable configuration for `OpenVPNSession`.
    public struct Configuration: Codable, Hashable, Sendable {
        struct Fallback {
            static let cipher: Cipher = .aes128cbc

            static let digest: Digest = .sha1

            static let compressionFraming: CompressionFraming = .disabled

            static let compressionAlgorithm: CompressionAlgorithm = .disabled
        }

        /// - Seealso: `Configuration.Builder.cipher`
        public let cipher: Cipher?

        /// - Seealso: `Configuration.Builder.dataCiphers`
        public let dataCiphers: [Cipher]?

        /// - Seealso: `Configuration.Builder.digest`
        public let digest: Digest?

        /// - Seealso: `Configuration.Builder.compressionFraming`
        public let compressionFraming: CompressionFraming?

        /// - Seealso: `Configuration.Builder.compressionAlgorithm`
        public let compressionAlgorithm: CompressionAlgorithm?

        /// - Seealso: `Configuration.Builder.ca`
        public let ca: CryptoContainer?

        /// - Seealso: `Configuration.Builder.clientCertificate`
        public let clientCertificate: CryptoContainer?

        /// - Seealso: `Configuration.Builder.clientKey`
        public let clientKey: CryptoContainer?

        /// - Seealso: `Configuration.Builder.tlsWrap`
        public let tlsWrap: TLSWrap?

        /// - Seealso: `Configuration.Builder.tlsSecurityLevel`
        public let tlsSecurityLevel: Int?

        /// - Seealso: `Configuration.Builder.keepAliveInterval`
        public let keepAliveInterval: TimeInterval?

        /// - Seealso: `Configuration.Builder.keepAliveTimeout`
        public let keepAliveTimeout: TimeInterval?

        /// - Seealso: `Configuration.Builder.renegotiatesAfter`
        public let renegotiatesAfter: TimeInterval?

        /// - Seealso: `Configuration.Builder.remotes`
        public let remotes: [ExtendedEndpoint]?

        /// - Seealso: `Configuration.Builder.checksEKU`
        public let checksEKU: Bool?

        /// - Seealso: `Configuration.Builder.verifyX509`
        public let verifyX509: VerifyX509?

        /// - Seealso: `Configuration.Builder.verifyX509Value`
        public let verifyX509Value: String?

        /// - Seealso: `Configuration.Builder.randomizeEndpoint`
        public let randomizeEndpoint: Bool?

        /// - Seealso: `Configuration.Builder.randomizeHostnames`
        public var randomizeHostnames: Bool?

        /// - Seealso: `Configuration.Builder.usesPIAPatches`
        public let usesPIAPatches: Bool?

        /// - Seealso: `Configuration.Builder.mtu`
        public let mtu: Int?

        /// - Seealso: `Configuration.Builder.authUserPass`
        public let authUserPass: Bool?

        /// - Seealso: `Configuration.Builder.staticChallenge`
        public let staticChallenge: Bool?

        /// - Seealso: `Configuration.Builder.authToken`
        public let authToken: String?

        /// - Seealso: `Configuration.Builder.peerId`
        public let peerId: UInt32?

        /// - Seealso: `Configuration.Builder.ipv4`
        public let ipv4: IPSettings?

        /// - Seealso: `Configuration.Builder.ipv6`
        public let ipv6: IPSettings?

        /// - Seealso: `Configuration.Builder.routes4`
        public let routes4: [Route]?

        /// - Seealso: `Configuration.Builder.routes6`
        public let routes6: [Route]?

        /// - Seealso: `Configuration.Builder.routeGateway4`
        public let routeGateway4: Address?

        /// - Seealso: `Configuration.Builder.routeGateway6`
        public let routeGateway6: Address?

        /// - Seealso: `Configuration.Builder.dnsServers`
        public let dnsServers: [String]?

        /// - Seealso: `Configuration.Builder.dnsDomain`
        public let dnsDomain: String?

        /// - Seealso: `Configuration.Builder.searchDomains`
        public let searchDomains: [String]?

        /// - Seealso: `Configuration.Builder.httpProxy`
        public let httpProxy: Endpoint?

        /// - Seealso: `Configuration.Builder.httpsProxy`
        public let httpsProxy: Endpoint?

        /// - Seealso: `Configuration.Builder.proxyAutoConfigurationURL`
        public let proxyAutoConfigurationURL: URL?

        /// - Seealso: `Configuration.Builder.proxyBypassDomains`
        public let proxyBypassDomains: [String]?

        /// - Seealso: `Configuration.Builder.routingPolicies`
        public let routingPolicies: [RoutingPolicy]?

        /// - Seealso: `Configuration.Builder.noPullMask`
        public let noPullMask: [PullMask]?

        /// - Seealso: `Configuration.Builder.xorMethod`
        public let xorMethod: ObfuscationMethod?

        // MARK: Shortcuts

        public var fallbackCipher: Cipher {
            return cipher ?? Fallback.cipher
        }

        public var fallbackDigest: Digest {
            return digest ?? Fallback.digest
        }

        public var fallbackCompressionFraming: CompressionFraming {
            return compressionFraming ?? Fallback.compressionFraming
        }

        public var fallbackCompressionAlgorithm: CompressionAlgorithm {
            return compressionAlgorithm ?? Fallback.compressionAlgorithm
        }
    }
}

extension OpenVPN.Configuration {
    @available(*, deprecated, message: "Use verifyX509 == .name")
    public var checksSANHost: Bool? {
        verifyX509 == .name ? true : nil
    }

    @available(*, deprecated, message: "Use verifyX509Value together with verifyX509 = .name")
    public var sanHost: String? {
        guard verifyX509 == .name else {
            return nil
        }
        return verifyX509Value
    }

    @available(*, deprecated, message: "Use verifyX509 == .subject")
    public var checksX509Subject: Bool? {
        verifyX509 == .subject ? true : nil
    }

    @available(*, deprecated, message: "Use verifyX509Value together with verifyX509 = .subject")
    public var x509Subject: String? {
        guard verifyX509 == .subject else {
            return nil
        }
        return verifyX509Value
    }
}

extension OpenVPN.Configuration {
    enum CodingKeys: String, CodingKey {
        case cipher
        case dataCiphers
        case digest
        case compressionFraming
        case compressionAlgorithm
        case ca
        case clientCertificate
        case clientKey
        case tlsWrap
        case tlsSecurityLevel
        case keepAliveInterval
        case keepAliveTimeout
        case renegotiatesAfter
        case remotes
        case checksEKU
        case verifyX509
        case verifyX509Value
        case randomizeEndpoint
        case randomizeHostnames
        case usesPIAPatches
        case mtu
        case authUserPass
        case staticChallenge
        case authToken
        case peerId
        case ipv4
        case ipv6
        case routes4
        case routes6
        case routeGateway4
        case routeGateway6
        case dnsServers
        case dnsDomain
        case searchDomains
        case httpProxy
        case httpsProxy
        case proxyAutoConfigurationURL
        case proxyBypassDomains
        case routingPolicies
        case noPullMask
        case xorMethod
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case checksSANHost
        case sanHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)

        let cipher = try container.decodeIfPresent(OpenVPN.Cipher.self, forKey: .cipher)
        let dataCiphers = try container.decodeIfPresent([OpenVPN.Cipher].self, forKey: .dataCiphers)
        let digest = try container.decodeIfPresent(OpenVPN.Digest.self, forKey: .digest)
        let compressionFraming = try container.decodeIfPresent(OpenVPN.CompressionFraming.self, forKey: .compressionFraming)
        let compressionAlgorithm = try container.decodeIfPresent(OpenVPN.CompressionAlgorithm.self, forKey: .compressionAlgorithm)
        let ca = try container.decodeIfPresent(OpenVPN.CryptoContainer.self, forKey: .ca)
        let clientCertificate = try container.decodeIfPresent(OpenVPN.CryptoContainer.self, forKey: .clientCertificate)
        let clientKey = try container.decodeIfPresent(OpenVPN.CryptoContainer.self, forKey: .clientKey)
        let tlsWrap = try container.decodeIfPresent(OpenVPN.TLSWrap.self, forKey: .tlsWrap)
        let tlsSecurityLevel = try container.decodeIfPresent(Int.self, forKey: .tlsSecurityLevel)
        let keepAliveInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .keepAliveInterval)
        let keepAliveTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .keepAliveTimeout)
        let renegotiatesAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .renegotiatesAfter)
        let remotes = try container.decodeIfPresent([ExtendedEndpoint].self, forKey: .remotes)
        let checksEKU = try container.decodeIfPresent(Bool.self, forKey: .checksEKU)
        let verifyX509 = try container.decodeIfPresent(OpenVPN.VerifyX509.self, forKey: .verifyX509)
            ?? {
                if try legacy.decodeIfPresent(Bool.self, forKey: .checksSANHost) == true {
                    return .name
                }
                return nil
            }()
        let verifyX509Value = try container.decodeIfPresent(String.self, forKey: .verifyX509Value)
            ?? {
                guard verifyX509 == .name else {
                    return nil
                }
                return try legacy.decodeIfPresent(String.self, forKey: .sanHost)
            }()
        let randomizeEndpoint = try container.decodeIfPresent(Bool.self, forKey: .randomizeEndpoint)
        let randomizeHostnames = try container.decodeIfPresent(Bool.self, forKey: .randomizeHostnames)
        let usesPIAPatches = try container.decodeIfPresent(Bool.self, forKey: .usesPIAPatches)
        let mtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        let authUserPass = try container.decodeIfPresent(Bool.self, forKey: .authUserPass)
        let staticChallenge = try container.decodeIfPresent(Bool.self, forKey: .staticChallenge)
        let authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        let peerId = try container.decodeIfPresent(UInt32.self, forKey: .peerId)
        let ipv4 = try container.decodeIfPresent(IPSettings.self, forKey: .ipv4)
        let ipv6 = try container.decodeIfPresent(IPSettings.self, forKey: .ipv6)
        let routes4 = try container.decodeIfPresent([Route].self, forKey: .routes4)
        let routes6 = try container.decodeIfPresent([Route].self, forKey: .routes6)
        let routeGateway4 = try container.decodeIfPresent(Address.self, forKey: .routeGateway4)
        let routeGateway6 = try container.decodeIfPresent(Address.self, forKey: .routeGateway6)
        let dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers)
        let dnsDomain = try container.decodeIfPresent(String.self, forKey: .dnsDomain)
        let searchDomains = try container.decodeIfPresent([String].self, forKey: .searchDomains)
        let httpProxy = try container.decodeIfPresent(Endpoint.self, forKey: .httpProxy)
        let httpsProxy = try container.decodeIfPresent(Endpoint.self, forKey: .httpsProxy)
        let proxyAutoConfigurationURL = try container.decodeIfPresent(URL.self, forKey: .proxyAutoConfigurationURL)
        let proxyBypassDomains = try container.decodeIfPresent([String].self, forKey: .proxyBypassDomains)
        let routingPolicies = try container.decodeIfPresent([OpenVPN.RoutingPolicy].self, forKey: .routingPolicies)
        let noPullMask = try container.decodeIfPresent([OpenVPN.PullMask].self, forKey: .noPullMask)
        let xorMethod = try container.decodeIfPresent(OpenVPN.ObfuscationMethod.self, forKey: .xorMethod)

        self = OpenVPN.Configuration(
            cipher: cipher,
            dataCiphers: dataCiphers,
            digest: digest,
            compressionFraming: compressionFraming,
            compressionAlgorithm: compressionAlgorithm,
            ca: ca,
            clientCertificate: clientCertificate,
            clientKey: clientKey,
            tlsWrap: tlsWrap,
            tlsSecurityLevel: tlsSecurityLevel,
            keepAliveInterval: keepAliveInterval,
            keepAliveTimeout: keepAliveTimeout,
            renegotiatesAfter: renegotiatesAfter,
            remotes: remotes,
            checksEKU: checksEKU,
            verifyX509: verifyX509,
            verifyX509Value: verifyX509Value,
            randomizeEndpoint: randomizeEndpoint,
            randomizeHostnames: randomizeHostnames,
            usesPIAPatches: usesPIAPatches,
            mtu: mtu,
            authUserPass: authUserPass,
            staticChallenge: staticChallenge,
            authToken: authToken,
            peerId: peerId,
            ipv4: ipv4,
            ipv6: ipv6,
            routes4: routes4,
            routes6: routes6,
            routeGateway4: routeGateway4,
            routeGateway6: routeGateway6,
            dnsServers: dnsServers,
            dnsDomain: dnsDomain,
            searchDomains: searchDomains,
            httpProxy: httpProxy,
            httpsProxy: httpsProxy,
            proxyAutoConfigurationURL: proxyAutoConfigurationURL,
            proxyBypassDomains: proxyBypassDomains,
            routingPolicies: routingPolicies,
            noPullMask: noPullMask,
            xorMethod: xorMethod
        )
    }
}

extension OpenVPN.Configuration: SerializableConfiguration {
    public func serialized() throws -> String {
        try asOvpnConfig()
    }
}

// MARK: - Builder

extension OpenVPN.Configuration {

    /// The way to create a `Configuration` object for a `OpenVPNSession`.
    public struct Builder: Hashable, Sendable {

        // MARK: General

        /// The cipher algorithm for data encryption.
        public var cipher: OpenVPN.Cipher?

        /// The set of supported cipher algorithms for data encryption (2.5.).
        public var dataCiphers: [OpenVPN.Cipher]?

        /// The digest algorithm for HMAC.
        public var digest: OpenVPN.Digest?

        /// Compression framing, disabled by default.
        public var compressionFraming: OpenVPN.CompressionFraming?

        /// Compression algorithm, disabled by default.
        public var compressionAlgorithm: OpenVPN.CompressionAlgorithm?

        /// The CA for TLS negotiation (PEM format).
        public var ca: OpenVPN.CryptoContainer?

        /// The optional client certificate for TLS negotiation (PEM format).
        public var clientCertificate: OpenVPN.CryptoContainer?

        /// The private key for the certificate in `clientCertificate` (PEM format).
        public var clientKey: OpenVPN.CryptoContainer?

        /// The optional TLS wrapping.
        public var tlsWrap: OpenVPN.TLSWrap?

        /// If set, overrides TLS security level (0 = lowest).
        public var tlsSecurityLevel: Int?

        /// Sends periodical keep-alive packets if set.
        public var keepAliveInterval: TimeInterval?

        /// Disconnects after no keep-alive packets are received within timeout interval if set.
        public var keepAliveTimeout: TimeInterval?

        /// The number of seconds after which a renegotiation should be initiated. If `nil`, the client will never initiate a renegotiation.
        public var renegotiatesAfter: TimeInterval?

        // MARK: Client

        /// The list of server endpoints.
        public var remotes: [ExtendedEndpoint]?

        /// If true, checks EKU of server certificate.
        public var checksEKU: Bool?

        /// Which `verify-x509-name` check to apply.
        public var verifyX509: OpenVPN.VerifyX509?

        /// The value used by `verify-x509-name`.
        public var verifyX509Value: String?

        /// Picks endpoint from `remotes` randomly.
        public var randomizeEndpoint: Bool?

        /// Prepend hostnames with a number of random bytes defined in `Configuration.randomHostnamePrefixLength`.
        public var randomizeHostnames: Bool?

        /// Server is patched for the PIA VPN provider.
        public var usesPIAPatches: Bool?

        /// The tunnel MTU.
        public var mtu: Int?

        /// Requires username authentication.
        public var authUserPass: Bool?

        /// Requires static challenge.
        public var staticChallenge: Bool?

        // MARK: Server

        /// The auth-token returned by the server.
        public var authToken: String?

        /// The peer-id returned by the server.
        public var peerId: UInt32?

        // MARK: Routing

        /// The settings for IPv4. Only evaluated when server-side.
        public var ipv4: IPSettings?

        /// The settings for IPv6. Only evaluated when Fserver-side.
        public var ipv6: IPSettings?

        /// The IPv4 routes if `ipv4` is nil.
        public var routes4: [Route]?

        /// The IPv6 routes if `ipv6` is nil.
        public var routes6: [Route]?

        /// The IPv4 gateway for routes.
        public var routeGateway4: Address?

        /// The IPv6 gateway for routes.
        public var routeGateway6: Address?

        /// The DNS protocol, defaults to `.plain`.
        public var dnsProtocol: DNSProtocol?

        /// The DNS servers if `dnsProtocol = .plain` or nil.
        public var dnsServers: [String]?

        /// The main domain name.
        public var dnsDomain: String?

        /// The search domain.
        @available(*, deprecated, message: "Use searchDomains instead")
        public var searchDomain: String? {
            didSet {
                guard let searchDomain = searchDomain else {
                    searchDomains = nil
                    return
                }
                searchDomains = [searchDomain]
            }
        }

        /// The search domains.
        public var searchDomains: [String]?

        /// The Proxy Auto-Configuration (PAC) url.
        public var proxyAutoConfigurationURL: URL?

        /// The HTTP proxy.
        public var httpProxy: Endpoint?

        /// The HTTPS proxy.
        public var httpsProxy: Endpoint?

        /// The list of domains not passing through the proxy.
        public var proxyBypassDomains: [String]?

        /// Policies for redirecting traffic through the VPN gateway.
        public var routingPolicies: [OpenVPN.RoutingPolicy]?

        /// Server settings that must not be pulled.
        public var noPullMask: [OpenVPN.PullMask]?

        // MARK: Extra

        /// The method to follow in regards to the XOR patch.
        public var xorMethod: OpenVPN.ObfuscationMethod?

        /**
         Creates a `Configuration.Builder`.

         - Parameter withFallbacks: If `true`, initializes builder with fallback values rather than nil.
         */
        public init(withFallbacks: Bool = false) {
            if withFallbacks {
                cipher = OpenVPN.Configuration.Fallback.cipher
                digest = OpenVPN.Configuration.Fallback.digest
                compressionFraming = OpenVPN.Configuration.Fallback.compressionFraming
                compressionAlgorithm = OpenVPN.Configuration.Fallback.compressionAlgorithm
            }
        }

        /**
         Builds a `Configuration` object.

         - Parameter isClient: If `true`, expect to build a full-fledged client configuration.
         - Returns: A ``OpenVPN/Configuration`` object with this builder.
         - Throws: If `isClient` is `true` and some required options are missing.
         */
        public func build(isClient: Bool) throws -> OpenVPN.Configuration {
            let fallbackCipher: OpenVPN.Cipher?
            if isClient {
                guard ca != nil else {
                    throw PartoutError.invalidFields(["ca": nil])
                }
                guard !(remotes?.isEmpty ?? true) else {
                    throw PartoutError.invalidFields(["remotes": nil])
                }
                guard verifyX509 == nil || verifyX509Value != nil else {
                    throw PartoutError.invalidFields(["verifyX509Value": nil])
                }
                fallbackCipher = cipher ?? .aes128cbc
            } else {
                fallbackCipher = cipher
            }
            return OpenVPN.Configuration(
                cipher: fallbackCipher,
                dataCiphers: dataCiphers,
                digest: digest,
                compressionFraming: compressionFraming,
                compressionAlgorithm: compressionAlgorithm,
                ca: ca,
                clientCertificate: clientCertificate,
                clientKey: clientKey,
                tlsWrap: tlsWrap,
                tlsSecurityLevel: tlsSecurityLevel,
                keepAliveInterval: keepAliveInterval,
                keepAliveTimeout: keepAliveTimeout,
                renegotiatesAfter: renegotiatesAfter,
                remotes: remotes,
                checksEKU: checksEKU,
                verifyX509: verifyX509,
                verifyX509Value: verifyX509Value,
                randomizeEndpoint: randomizeEndpoint,
                randomizeHostnames: randomizeHostnames,
                usesPIAPatches: usesPIAPatches,
                mtu: mtu,
                authUserPass: authUserPass,
                staticChallenge: staticChallenge,
                authToken: authToken,
                peerId: peerId,
                ipv4: ipv4,
                ipv6: ipv6,
                routes4: routes4,
                routes6: routes6,
                routeGateway4: routeGateway4,
                routeGateway6: routeGateway6,
                dnsServers: dnsServers,
                dnsDomain: dnsDomain,
                searchDomains: searchDomains,
                httpProxy: httpProxy,
                httpsProxy: httpsProxy,
                proxyAutoConfigurationURL: proxyAutoConfigurationURL,
                proxyBypassDomains: proxyBypassDomains,
                routingPolicies: routingPolicies,
                noPullMask: noPullMask,
                xorMethod: xorMethod
            )
        }
    }
}

extension OpenVPN.Configuration.Builder {
    @available(*, deprecated, message: "Use verifyX509 == .name")
    public var checksSANHost: Bool? {
        get {
            verifyX509 == .name ? true : nil
        }
        set {
            guard newValue == true else {
                if verifyX509 == .name {
                    verifyX509 = nil
                }
                return
            }
            verifyX509 = .name
        }
    }

    @available(*, deprecated, message: "Use verifyX509Value together with verifyX509 = .name")
    public var sanHost: String? {
        get {
            guard verifyX509 == .name else {
                return nil
            }
            return verifyX509Value
        }
        set {
            verifyX509Value = newValue
        }
    }

    @available(*, deprecated, message: "Use verifyX509 == .subject")
    public var checksX509Subject: Bool? {
        get {
            verifyX509 == .subject ? true : nil
        }
        set {
            guard newValue == true else {
                if verifyX509 == .subject {
                    verifyX509 = nil
                }
                return
            }
            verifyX509 = .subject
        }
    }

    @available(*, deprecated, message: "Use verifyX509Value together with verifyX509 = .subject")
    public var x509Subject: String? {
        get {
            guard verifyX509 == .subject else {
                return nil
            }
            return verifyX509Value
        }
        set {
            verifyX509Value = newValue
        }
    }
}

// MARK: - Modification

extension OpenVPN.Configuration {

    /**
     Returns a `Configuration.Builder` to use this configuration as a starting point for a new one.
     
     - Parameter withFallbacks: If `true`, initializes builder with fallback values rather than nil.
     - Returns: An editable `Configuration.Builder` initialized with this configuration.
     */
    public func builder(withFallbacks: Bool = false) -> OpenVPN.Configuration.Builder {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = cipher ?? (withFallbacks ? Fallback.cipher : nil)
        builder.dataCiphers = dataCiphers
        builder.digest = digest ?? (withFallbacks ? Fallback.digest : nil)
        builder.compressionFraming = compressionFraming ?? (withFallbacks ? Fallback.compressionFraming : nil)
        builder.compressionAlgorithm = compressionAlgorithm ?? (withFallbacks ? Fallback.compressionAlgorithm : nil)
        builder.ca = ca
        builder.clientCertificate = clientCertificate
        builder.clientKey = clientKey
        builder.tlsWrap = tlsWrap
        builder.tlsSecurityLevel = tlsSecurityLevel
        builder.keepAliveInterval = keepAliveInterval
        builder.keepAliveTimeout = keepAliveTimeout
        builder.renegotiatesAfter = renegotiatesAfter
        builder.remotes = remotes
        builder.checksEKU = checksEKU
        builder.verifyX509 = verifyX509
        builder.verifyX509Value = verifyX509Value
        builder.randomizeEndpoint = randomizeEndpoint
        builder.randomizeHostnames = randomizeHostnames
        builder.usesPIAPatches = usesPIAPatches
        builder.mtu = mtu
        builder.authUserPass = authUserPass
        builder.staticChallenge = staticChallenge
        builder.authToken = authToken
        builder.peerId = peerId
        builder.ipv4 = ipv4
        builder.ipv6 = ipv6
        builder.routes4 = routes4
        builder.routes6 = routes6
        builder.dnsServers = dnsServers
        builder.dnsDomain = dnsDomain
        builder.searchDomains = searchDomains
        builder.httpProxy = httpProxy
        builder.httpsProxy = httpsProxy
        builder.proxyAutoConfigurationURL = proxyAutoConfigurationURL
        builder.proxyBypassDomains = proxyBypassDomains
        builder.routingPolicies = routingPolicies
        builder.noPullMask = noPullMask
        builder.xorMethod = xorMethod
        return builder
    }
}

// MARK: - Debugging

extension OpenVPN.Configuration {
    public func print(_ ctx: PartoutLoggerContext, isLocal: Bool) {
        if isLocal, let remotes {
            pp_log(ctx, .openvpn, .notice, "\tRemotes: \(remotes.map { $0.asSensitiveAddress(ctx) })")
        }

        if !isLocal {
            pp_log(ctx, .openvpn, .notice, "\tIPv4: \(ipv4?.asSensitiveAddress(ctx) ?? "not configured")")
            pp_log(ctx, .openvpn, .notice, "\tIPv6: \(ipv6?.asSensitiveAddress(ctx) ?? "not configured")")
        }
        if let routes4 {
            pp_log(ctx, .openvpn, .notice, "\tRoutes (IPv4): \(routes4)")
        }
        if let routes6 {
            pp_log(ctx, .openvpn, .notice, "\tRoutes (IPv6): \(routes6)")
        }

        if let cipher {
            pp_log(ctx, .openvpn, .notice, "\tCipher: \(cipher)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tCipher: \(fallbackCipher)")
        }
        if let digest {
            pp_log(ctx, .openvpn, .notice, "\tDigest: \(digest)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tDigest: \(fallbackDigest)")
        }
        if let compressionFraming {
            pp_log(ctx, .openvpn, .notice, "\tCompression framing: \(compressionFraming)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tCompression framing: \(fallbackCompressionFraming)")
        }
        if let compressionAlgorithm {
            pp_log(ctx, .openvpn, .notice, "\tCompression algorithm: \(compressionAlgorithm)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tCompression algorithm: \(fallbackCompressionAlgorithm)")
        }

        if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tUsername authentication: \(authUserPass ?? false)")
            pp_log(ctx, .openvpn, .notice, "\tStatic challenge: \(staticChallenge ?? false)")
            if clientCertificate != nil {
                pp_log(ctx, .openvpn, .notice, "\tClient verification: enabled")
            } else {
                pp_log(ctx, .openvpn, .notice, "\tClient verification: disabled")
            }
            if let tlsWrap {
                pp_log(ctx, .openvpn, .notice, "\tTLS wrapping: \(tlsWrap.strategy.rawValue)")
            } else {
                pp_log(ctx, .openvpn, .notice, "\tTLS wrapping: disabled")
            }
            if let tlsSecurityLevel {
                pp_log(ctx, .openvpn, .notice, "\tTLS security level: \(tlsSecurityLevel)")
            } else {
                pp_log(ctx, .openvpn, .notice, "\tTLS security level: default")
            }
        }

        if let keepAliveInterval, keepAliveInterval > 0 {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive interval: \(keepAliveInterval.asTimeString)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive interval: never")
        }
        if let keepAliveTimeout, keepAliveTimeout > 0 {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive timeout: \(keepAliveTimeout.asTimeString)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive timeout: never")
        }
        if let renegotiatesAfter, renegotiatesAfter > 0 {
            pp_log(ctx, .openvpn, .notice, "\tRenegotiation: \(renegotiatesAfter.asTimeString)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tRenegotiation: never")
        }
        if checksEKU ?? false {
            pp_log(ctx, .openvpn, .notice, "\tServer EKU verification: enabled")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tServer EKU verification: disabled")
        }
        switch verifyX509 {
        case .name:
            pp_log(ctx, .openvpn, .notice, "\tHost SAN verification: enabled (\(verifyX509Value?.asSensitiveAddress(ctx) ?? "-"))")
            if isLocal {
                pp_log(ctx, .openvpn, .notice, "\tSubject DN verification: disabled")
            }
        case .subject:
            if isLocal {
                pp_log(ctx, .openvpn, .notice, "\tHost SAN verification: disabled")
            }
            pp_log(ctx, .openvpn, .notice, "\tSubject DN verification: enabled (\(verifyX509Value ?? "-"))")
        case nil:
            if isLocal {
                pp_log(ctx, .openvpn, .notice, "\tHost SAN verification: disabled")
                pp_log(ctx, .openvpn, .notice, "\tSubject DN verification: disabled")
            }
        }

        if randomizeEndpoint ?? false {
            pp_log(ctx, .openvpn, .notice, "\tRandomize endpoint: true")
        }
        if randomizeHostnames ?? false {
            pp_log(ctx, .openvpn, .notice, "\tRandomize hostnames: true")
        }

        if let routingPolicies {
            pp_log(ctx, .openvpn, .notice, "\tGateway: \(routingPolicies.map(\.rawValue))")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tGateway: not configured")
        }

        if let dnsServers, !dnsServers.isEmpty {
            pp_log(ctx, .openvpn, .notice, "\tDNS: \(dnsServers.map { $0.asSensitiveAddress(ctx) })")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tDNS: not configured")
        }
        if let dnsDomain, !dnsDomain.isEmpty {
            pp_log(ctx, .openvpn, .notice, "\tDNS domain: \(dnsDomain.asSensitiveAddress(ctx))")
        }
        if let searchDomains, !searchDomains.isEmpty {
            pp_log(ctx, .openvpn, .notice, "\tSearch domains: \(searchDomains.map { $0.asSensitiveAddress(ctx) })")
        }

        if let httpProxy {
            pp_log(ctx, .openvpn, .notice, "\tHTTP proxy: \(httpProxy.asSensitiveAddress(ctx))")
        }
        if let httpsProxy {
            pp_log(ctx, .openvpn, .notice, "\tHTTPS proxy: \(httpsProxy.asSensitiveAddress(ctx))")
        }
        if let proxyAutoConfigurationURL {
            pp_log(ctx, .openvpn, .notice, "\tPAC: \(proxyAutoConfigurationURL.absoluteString.asSensitiveAddress(ctx))")
        }
        if let proxyBypassDomains {
            pp_log(ctx, .openvpn, .notice, "\tProxy bypass domains: \(proxyBypassDomains.map { $0.asSensitiveAddress(ctx) })")
        }

        if let mtu {
            pp_log(ctx, .openvpn, .notice, "\tMTU: \(mtu)")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tMTU: default")
        }

        if let xorMethod {
            switch xorMethod {
            case .obfuscate:
                pp_log(ctx, .openvpn, .notice, "\tXOR: obfuscate")
            case .reverse:
                pp_log(ctx, .openvpn, .notice, "\tXOR: reverse")
            case .xormask:
                pp_log(ctx, .openvpn, .notice, "\tXOR: xormask")
            case .xorptrpos:
                pp_log(ctx, .openvpn, .notice, "\tXOR: xorptrpos")
            }
        }

        if isLocal, let noPullMask {
            pp_log(ctx, .openvpn, .notice, "\tNot pulled: \(noPullMask.map(\.rawValue))")
        }
    }
}

extension OpenVPN.Cipher: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

extension OpenVPN.Digest: CustomStringConvertible {
    public var description: String {
        return "\(genericName)-\(rawValue)"
    }
}

// MARK: - Extensions

extension OpenVPN.Configuration {
    public var pullMask: [OpenVPN.PullMask]? {
        toPullMask(from: noPullMask)
    }
}

extension OpenVPN.Configuration.Builder {
    public var pullMask: [OpenVPN.PullMask]? {
        toPullMask(from: noPullMask)
    }
}

private func toPullMask(from noPullMask: [OpenVPN.PullMask]?) -> [OpenVPN.PullMask]? {
    let all = OpenVPN.PullMask.allCases
    guard let notPulled = noPullMask else {
        return all
    }
    let pulled = Array(Set(all).subtracting(notPulled))
    return !pulled.isEmpty ? pulled : nil
}
