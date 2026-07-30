// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN.Cipher {
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
        rawValue.hasSuffix("-GCM")
    }

    /// Returns a generic name for this cipher.
    public var genericName: String {
        rawValue.hasSuffix("-GCM") ? "AES-GCM" : "AES-CBC"
    }
}

extension OpenVPN.Digest {
    /// Returns a generic name for this digest.
    public var genericName: String {
        "HMAC"
    }
}

extension OpenVPN.Cipher: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension OpenVPN.Digest: CustomStringConvertible {
    public var description: String {
        "\(genericName)-\(rawValue)"
    }
}

private enum OpenVPNConfigurationFallback {
    static let cipher: OpenVPN.Cipher = .aes128cbc
    static let digest: OpenVPN.Digest = .sha1
    static let compressionFraming: OpenVPN.CompressionFraming = .disabled
    static let compressionAlgorithm: OpenVPN.CompressionAlgorithm = .disabled
}

extension OpenVPN.Configuration {
    /// Returns the effective cipher to use when negotiation does not yield one.
    ///
    /// `cipher` takes precedence because the parser also uses it to store
    /// `data-ciphers-fallback`, allowing deprecated `cipher` input to be
    /// normalized to the modern fallback form on serialization.
    public var fallbackCipher: OpenVPN.Cipher {
        cipher ?? dataCiphers?.first ?? OpenVPNConfigurationFallback.cipher
    }

    public var fallbackDigest: OpenVPN.Digest {
        digest ?? OpenVPNConfigurationFallback.digest
    }

    public var fallbackCompressionFraming: OpenVPN.CompressionFraming {
        compressionFraming ?? OpenVPNConfigurationFallback.compressionFraming
    }

    public var fallbackCompressionAlgorithm: OpenVPN.CompressionAlgorithm {
        compressionAlgorithm ?? OpenVPNConfigurationFallback.compressionAlgorithm
    }
}

extension OpenVPN.Configuration {
    /// The way to create a `Configuration` object for a `OpenVPNSession`.
    public struct Builder: Hashable, Sendable {
        /// The legacy cipher algorithm for data encryption.
        ///
        /// When `dataCiphers` is set, this same field also stores the effective
        /// `data-ciphers-fallback` value so deprecated `cipher` input can be
        /// normalized on output.
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

        /// The list of server endpoints.
        public var remotes: [ExtendedEndpoint]?

        /// If true, checks EKU of server certificate.
        public var checksEKU: Bool?

        /// If true, checks if hostname (sanHost) is present in certificates SAN.
        public var checksSANHost: Bool?

        /// The server hostname used for checking certificate SAN.
        public var sanHost: String?

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

        /// The auth-token returned by the server.
        public var authToken: String?

        /// The peer-id returned by the server.
        public var peerId: UInt32?

        /// The settings for IPv4. Only evaluated when server-side.
        public var ipv4: IPSettings?

        /// The settings for IPv6. Only evaluated when server-side.
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

        /// The method to follow in regards to the XOR patch.
        public var xorMethod: OpenVPN.ObfuscationMethod?

        /**
         Creates a `Configuration.Builder`.

         - Parameter withFallbacks: If `true`, initializes builder with fallback values rather than nil.
         */
        public init(withFallbacks: Bool = false) {
            if withFallbacks {
                cipher = OpenVPNConfigurationFallback.cipher
                digest = OpenVPNConfigurationFallback.digest
                compressionFraming = OpenVPNConfigurationFallback.compressionFraming
                compressionAlgorithm = OpenVPNConfigurationFallback.compressionAlgorithm
            }
        }

        /**
         Builds a `Configuration` object.

         - Parameter isClient: If `true`, expect to build a full-fledged client configuration.
         - Returns: A ``OpenVPN/Configuration`` object with this builder.
         - Throws: If `isClient` is `true` and some required options are missing.
         */
        public func build(isClient: Bool) throws -> OpenVPN.Configuration {
            if isClient {
                guard ca != nil else {
                    throw PartoutError.invalidField(.OpenVPN.ca)
                }
                guard !(remotes?.isEmpty ?? true) else {
                    throw PartoutError.invalidField(.OpenVPN.remotes)
                }
            }
            return OpenVPN.Configuration(
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
                checksSANHost: checksSANHost,
                sanHost: sanHost,
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

extension OpenVPN.Configuration {
    /**
     Returns a `Configuration.Builder` to use this configuration as a starting point for a new one.

     - Parameter withFallbacks: If `true`, initializes builder with fallback values rather than nil.
     - Returns: An editable `Configuration.Builder` initialized with this configuration.
     */
    public func builder(withFallbacks: Bool = false) -> OpenVPN.Configuration.Builder {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = cipher ?? (withFallbacks ? OpenVPNConfigurationFallback.cipher : nil)
        builder.dataCiphers = dataCiphers
        builder.digest = digest ?? (withFallbacks ? OpenVPNConfigurationFallback.digest : nil)
        builder.compressionFraming = compressionFraming ?? (withFallbacks ? OpenVPNConfigurationFallback.compressionFraming : nil)
        builder.compressionAlgorithm = compressionAlgorithm ?? (withFallbacks ? OpenVPNConfigurationFallback.compressionAlgorithm : nil)
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
        builder.checksSANHost = checksSANHost
        builder.sanHost = sanHost
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
