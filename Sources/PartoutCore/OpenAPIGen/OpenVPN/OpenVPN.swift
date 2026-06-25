// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


/// Container of all OpenVPN entities.
public enum OpenVPN {
}

extension OpenVPN {
    /// Encryption algorithm.
    public enum Cipher: String, Hashable, Codable, Sendable {
        case aes128cbc = "AES-128-CBC"
        case aes192cbc = "AES-192-CBC"
        case aes256cbc = "AES-256-CBC"
        case aes128gcm = "AES-128-GCM"
        case aes192gcm = "AES-192-GCM"
        case aes256gcm = "AES-256-GCM"
    }

    /// Message digest algorithm.
    public enum Digest: String, Hashable, Codable, Sendable {
        case sha1 = "SHA1"
        case sha224 = "SHA224"
        case sha256 = "SHA256"
        case sha384 = "SHA384"
        case sha512 = "SHA512"
    }

    /// Routing policy.
    public enum RoutingPolicy: String, Hashable, Codable, Sendable {
        case IPv4
        case IPv6
        case blockLocal
    }

    /// Settings that can be pulled from server.
    public enum PullMask: String, Hashable, Codable, CaseIterable, Sendable {
        case routes
        case dns
        case proxy
    }

    /// Defines the type of compression algorithm.
    public enum CompressionAlgorithm: Int, Codable, Sendable {
        case disabled
        case LZO
        case other
    }

    /// Defines the type of compression framing.
    public enum CompressionFraming: Int, Codable, Sendable {
        case disabled
        case compLZO
        case compress
        case compressV2
    }

    /// The obfuscation method.
    public enum ObfuscationMethod: Hashable, Codable, Sendable {
        case xormask(mask: SecureData)
        case xorptrpos
        case reverse
        case obfuscate(mask: SecureData)
    }

    /// Represents a cryptographic container in PEM format.
    public struct CryptoContainer: Hashable, Sendable {
        public let pem: String
    }

    /// Represents an OpenVPN static key file (as generated with --genkey).
    public struct StaticKey: Hashable, Codable, Sendable {
        enum CodingKeys: String, CodingKey {
            case secureData = "data"
            case direction = "dir"
        }

        public enum Direction: Int, Hashable, Codable, Sendable {
            case server = 0
            case client = 1
        }

        public let secureData: SecureData
        public let direction: Direction?

        public init(secureData: SecureData, direction: Direction?) {
            self.secureData = secureData
            self.direction = direction
        }
    }

    /// Holds parameters for TLS wrapping.
    public struct TLSWrap: Hashable, Codable, Sendable {
        public enum Strategy: String, Hashable, Codable, Sendable {
            case auth
            case crypt
            case cryptV2 = "crypt-v2"
        }

        public let strategy: Strategy
        public let key: StaticKey
        public let wrappedKey: SecureData?
    }

    /// A set of credentials for authentication.
    public struct Credentials: Hashable, Sendable {
        public enum OTPMethod: String, Hashable, Codable, Sendable {
            case none
            case append
            case encode
        }

        public let username: String
        public let password: String
        public let otpMethod: OTPMethod
        public let otp: String?

        public init(username: String, password: String, otpMethod: OTPMethod, otp: String?) {
            self.username = username
            self.password = password
            self.otpMethod = otpMethod
            self.otp = otp
        }
    }

    /// The immutable configuration for `OpenVPNSession`.
    public struct Configuration: Codable, Hashable, Sendable {
        public let cipher: Cipher?
        public let dataCiphers: [Cipher]?
        public let digest: Digest?
        public let compressionFraming: CompressionFraming?
        public let compressionAlgorithm: CompressionAlgorithm?
        public let ca: CryptoContainer?
        public let clientCertificate: CryptoContainer?
        public let clientKey: CryptoContainer?
        public let tlsWrap: TLSWrap?
        public let tlsSecurityLevel: Int?
        public let keepAliveInterval: TimeInterval?
        public let keepAliveTimeout: TimeInterval?
        public let renegotiatesAfter: TimeInterval?
        public let remotes: [ExtendedEndpoint]?
        public let checksEKU: Bool?
        public let checksSANHost: Bool?
        public let sanHost: String?
        public let randomizeEndpoint: Bool?
        public var randomizeHostnames: Bool?
        public let usesPIAPatches: Bool?
        public let mtu: Int?
        public let authUserPass: Bool?
        public let staticChallenge: Bool?
        public let authToken: String?
        public let peerId: UInt32?
        public let ipv4: IPSettings?
        public let ipv6: IPSettings?
        public let routes4: [Route]?
        public let routes6: [Route]?
        public let routeGateway4: Address?
        public let routeGateway6: Address?
        public let dnsServers: [String]?
        public let dnsDomain: String?
        public let searchDomains: [String]?
        public let httpProxy: Endpoint?
        public let httpsProxy: Endpoint?
        public let proxyAutoConfigurationURL: URL?
        public let proxyBypassDomains: [String]?
        public let routingPolicies: [RoutingPolicy]?
        public let noPullMask: [PullMask]?
        public let xorMethod: ObfuscationMethod?

        public init(
            cipher: Cipher?,
            dataCiphers: [Cipher]?,
            digest: Digest?,
            compressionFraming: CompressionFraming?,
            compressionAlgorithm: CompressionAlgorithm?,
            ca: CryptoContainer?,
            clientCertificate: CryptoContainer?,
            clientKey: CryptoContainer?,
            tlsWrap: TLSWrap?,
            tlsSecurityLevel: Int?,
            keepAliveInterval: TimeInterval?,
            keepAliveTimeout: TimeInterval?,
            renegotiatesAfter: TimeInterval?,
            remotes: [ExtendedEndpoint]?,
            checksEKU: Bool?,
            checksSANHost: Bool?,
            sanHost: String?,
            randomizeEndpoint: Bool?,
            randomizeHostnames: Bool?,
            usesPIAPatches: Bool?,
            mtu: Int?,
            authUserPass: Bool?,
            staticChallenge: Bool?,
            authToken: String?,
            peerId: UInt32?,
            ipv4: IPSettings?,
            ipv6: IPSettings?,
            routes4: [Route]?,
            routes6: [Route]?,
            routeGateway4: Address?,
            routeGateway6: Address?,
            dnsServers: [String]?,
            dnsDomain: String?,
            searchDomains: [String]?,
            httpProxy: Endpoint?,
            httpsProxy: Endpoint?,
            proxyAutoConfigurationURL: URL?,
            proxyBypassDomains: [String]?,
            routingPolicies: [RoutingPolicy]?,
            noPullMask: [PullMask]?,
            xorMethod: ObfuscationMethod?
        ) {
            self.cipher = cipher
            self.dataCiphers = dataCiphers
            self.digest = digest
            self.compressionFraming = compressionFraming
            self.compressionAlgorithm = compressionAlgorithm
            self.ca = ca
            self.clientCertificate = clientCertificate
            self.clientKey = clientKey
            self.tlsWrap = tlsWrap
            self.tlsSecurityLevel = tlsSecurityLevel
            self.keepAliveInterval = keepAliveInterval
            self.keepAliveTimeout = keepAliveTimeout
            self.renegotiatesAfter = renegotiatesAfter
            self.remotes = remotes
            self.checksEKU = checksEKU
            self.checksSANHost = checksSANHost
            self.sanHost = sanHost
            self.randomizeEndpoint = randomizeEndpoint
            self.randomizeHostnames = randomizeHostnames
            self.usesPIAPatches = usesPIAPatches
            self.mtu = mtu
            self.authUserPass = authUserPass
            self.staticChallenge = staticChallenge
            self.authToken = authToken
            self.peerId = peerId
            self.ipv4 = ipv4
            self.ipv6 = ipv6
            self.routes4 = routes4
            self.routes6 = routes6
            self.routeGateway4 = routeGateway4
            self.routeGateway6 = routeGateway6
            self.dnsServers = dnsServers
            self.dnsDomain = dnsDomain
            self.searchDomains = searchDomains
            self.httpProxy = httpProxy
            self.httpsProxy = httpsProxy
            self.proxyAutoConfigurationURL = proxyAutoConfigurationURL
            self.proxyBypassDomains = proxyBypassDomains
            self.routingPolicies = routingPolicies
            self.noPullMask = noPullMask
            self.xorMethod = xorMethod
        }
    }
}

/// A connection module providing an OpenVPN connection.
public struct OpenVPNModule: Hashable, Codable, Sendable {
    public let id: UniqueID
    public let configuration: OpenVPN.Configuration?
    public let credentials: OpenVPN.Credentials?
    internal let requiresInteractiveCredentials: Bool?

    public init(
        id: UniqueID,
        configuration: OpenVPN.Configuration?,
        credentials: OpenVPN.Credentials?,
        requiresInteractiveCredentials: Bool?
    ) {
        self.id = id
        self.configuration = configuration
        self.credentials = credentials
        self.requiresInteractiveCredentials = requiresInteractiveCredentials
    }
}
