// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
extension OpenVPN.Cipher {
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

    public var embedsDigest: Bool {
        rawValue.hasSuffix("-GCM")
    }

    public var genericName: String {
        rawValue.hasSuffix("-GCM") ? "AES-GCM" : "AES-CBC"
    }
}

extension OpenVPN.Digest {
    public var genericName: String {
        "HMAC"
    }
}

private enum OpenVPNConfigurationFallback {
    static let cipher: OpenVPN.Cipher = .aes128cbc
    static let digest: OpenVPN.Digest = .sha1
    static let compressionFraming: OpenVPN.CompressionFraming = .disabled
    static let compressionAlgorithm: OpenVPN.CompressionAlgorithm = .disabled
}

extension OpenVPN.Configuration {
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
    public struct Builder: Hashable, Sendable {
        public var cipher: OpenVPN.Cipher?
        public var dataCiphers: [OpenVPN.Cipher]?
        public var digest: OpenVPN.Digest?
        public var compressionFraming: OpenVPN.CompressionFraming?
        public var compressionAlgorithm: OpenVPN.CompressionAlgorithm?
        public var ca: OpenVPN.CryptoContainer?
        public var clientCertificate: OpenVPN.CryptoContainer?
        public var clientKey: OpenVPN.CryptoContainer?
        public var tlsWrap: OpenVPN.TLSWrap?
        public var tlsSecurityLevel: Int?
        public var keepAliveInterval: TimeInterval?
        public var keepAliveTimeout: TimeInterval?
        public var renegotiatesAfter: TimeInterval?
        public var remotes: [ExtendedEndpoint]?
        public var checksEKU: Bool?
        public var checksSANHost: Bool?
        public var sanHost: String?
        public var randomizeEndpoint: Bool?
        public var randomizeHostnames: Bool?
        public var usesPIAPatches: Bool?
        public var mtu: Int?
        public var authUserPass: Bool?
        public var staticChallenge: Bool?
        public var authToken: String?
        public var peerId: UInt32?
        public var ipv4: IPSettings?
        public var ipv6: IPSettings?
        public var routes4: [Route]?
        public var routes6: [Route]?
        public var routeGateway4: Address?
        public var routeGateway6: Address?
        public var dnsProtocol: DNSProtocol?
        public var dnsServers: [String]?
        public var dnsDomain: String?
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
        public var searchDomains: [String]?
        public var proxyAutoConfigurationURL: URL?
        public var httpProxy: Endpoint?
        public var httpsProxy: Endpoint?
        public var proxyBypassDomains: [String]?
        public var routingPolicies: [OpenVPN.RoutingPolicy]?
        public var noPullMask: [OpenVPN.PullMask]?
        public var xorMethod: OpenVPN.ObfuscationMethod?

        public init(withFallbacks: Bool = false) {
            if withFallbacks {
                cipher = OpenVPNConfigurationFallback.cipher
                digest = OpenVPNConfigurationFallback.digest
                compressionFraming = OpenVPNConfigurationFallback.compressionFraming
                compressionAlgorithm = OpenVPNConfigurationFallback.compressionAlgorithm
            }
        }

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
                authToken: authToken,
                authUserPass: authUserPass,
                ca: ca,
                checksEKU: checksEKU,
                checksSANHost: checksSANHost,
                cipher: cipher,
                clientCertificate: clientCertificate,
                clientKey: clientKey,
                compressionAlgorithm: compressionAlgorithm,
                compressionFraming: compressionFraming,
                dataCiphers: dataCiphers,
                digest: digest,
                dnsDomain: dnsDomain,
                dnsServers: dnsServers,
                httpProxy: httpProxy,
                httpsProxy: httpsProxy,
                ipv4: ipv4,
                ipv6: ipv6,
                keepAliveInterval: keepAliveInterval,
                keepAliveTimeout: keepAliveTimeout,
                mtu: mtu,
                noPullMask: noPullMask,
                peerId: peerId,
                proxyAutoConfigurationURL: proxyAutoConfigurationURL,
                proxyBypassDomains: proxyBypassDomains,
                randomizeEndpoint: randomizeEndpoint,
                randomizeHostnames: randomizeHostnames,
                remotes: remotes,
                renegotiatesAfter: renegotiatesAfter,
                routeGateway4: routeGateway4,
                routeGateway6: routeGateway6,
                routes4: routes4,
                routes6: routes6,
                routingPolicies: routingPolicies,
                sanHost: sanHost,
                searchDomains: searchDomains,
                staticChallenge: staticChallenge,
                tlsSecurityLevel: tlsSecurityLevel,
                tlsWrap: tlsWrap,
                usesPIAPatches: usesPIAPatches,
                xorMethod: xorMethod
            )
        }
    }
}

extension OpenVPN.Configuration {
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
