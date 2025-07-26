// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

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

        /// - Seealso: `Configuration.Builder.checksSANHost`
        public let checksSANHost: Bool?

        /// - Seealso: `Configuration.Builder.sanHost`
        public let sanHost: String?

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

// MARK: - Builder

extension OpenVPN.Configuration {

    /// The way to create a `Configuration` object for a `OpenVPNSession`.
    public struct Builder: Hashable {

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
        public func tryBuild(isClient: Bool) throws -> OpenVPN.Configuration {
            let fallbackCipher: OpenVPN.Cipher?
            if isClient {
                guard ca != nil else {
                    throw PartoutError.invalidFields(["ca": nil])
                }
                guard !(remotes?.isEmpty ?? true) else {
                    throw PartoutError.invalidFields(["remotes": nil])
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
        if checksSANHost ?? false {
            pp_log(ctx, .openvpn, .notice, "\tHost SAN verification: enabled (\(sanHost?.asSensitiveAddress(ctx) ?? "-"))")
        } else if isLocal {
            pp_log(ctx, .openvpn, .notice, "\tHost SAN verification: disabled")
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
