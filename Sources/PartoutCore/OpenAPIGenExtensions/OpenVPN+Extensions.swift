// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension LoggerCategory {
    public static let openvpn = Self(rawValue: "openvpn")
}

// XXX: Workaround for name clash
/// Alias for ``OpenVPN/Configuration``.
public typealias OpenVPNConfiguration = OpenVPN.Configuration

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

extension OpenVPN.CompressionAlgorithm: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disabled:
            return "disabled"
        case .LZO:
            return "lzo"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}

extension OpenVPN.CompressionFraming: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disabled:
            return "disabled"
        case .compress:
            return "compress"
        case .compressV2:
            return "compress"
        case .compLZO:
            return "comp-lzo"
        @unknown default:
            return "unknown"
        }
    }
}

extension OpenVPN.ObfuscationMethod {
    public var mask: SecureData? {
        switch self {
        case .xormask(let mask):
            return mask
        case .obfuscate(let mask):
            return mask
        default:
            return nil
        }
    }
}

extension OpenVPN.ObfuscationMethod {
    enum Discriminator: String, Codable {
        case xormask
        case xorptrpos
        case reverse
        case obfuscate
    }

    enum CodingKeys: String, CodingKey {
        case type
        case mask
    }

    enum LegacyCodingKeys: String, CodingKey {
        case xormask
        case xorptrpos
        case reverse
        case obfuscate
    }

    enum LegacyMaskCodingKeys: String, CodingKey {
        case mask
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
        guard let discriminator = try container.decodeIfPresent(Discriminator.self, forKey: .type) else {
            return nil
        }
        switch discriminator {
        case .xormask:
            let mask = try container.decode(SecureData.self, forKey: .mask)
            return .xormask(mask: mask)
        case .xorptrpos:
            return .xorptrpos
        case .reverse:
            return .reverse
        case .obfuscate:
            let mask = try container.decode(SecureData.self, forKey: .mask)
            return .obfuscate(mask: mask)
        }
    }

    private static func fromLegacy(decoder: any Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if container.contains(.xormask) {
            let map = try container.superDecoder(forKey: .xormask)
            let sub = try map.container(keyedBy: LegacyMaskCodingKeys.self)
            let mask = try sub.decode(SecureData.self, forKey: .mask)
            return .xormask(mask: mask)
        }
        if container.contains(.xorptrpos) {
            return .xorptrpos
        }
        if container.contains(.reverse) {
            return .reverse
        }
        if container.contains(.obfuscate) {
            let map = try container.superDecoder(forKey: .obfuscate)
            let sub = try map.container(keyedBy: LegacyMaskCodingKeys.self)
            let mask = try sub.decode(SecureData.self, forKey: .mask)
            return .obfuscate(mask: mask)
        }
        throw PartoutError(.decoding)
    }

    public func encode(to encoder: any Encoder) throws {
        if encoder.userInfo.usesLegacySwiftEncoding {
            var container = encoder.singleValueContainer()
            let map: [String: [String: String]]
            switch self {
            case .xormask(let mask):
                map = [
                    LegacyCodingKeys.xormask.rawValue: [
                        LegacyMaskCodingKeys.mask.rawValue: mask.toData().base64EncodedString()
                    ]
                ]
            case .xorptrpos:
                map = [LegacyCodingKeys.xorptrpos.rawValue: [:]]
            case .reverse:
                map = [LegacyCodingKeys.reverse.rawValue: [:]]
            case .obfuscate(let mask):
                map = [
                    LegacyCodingKeys.obfuscate.rawValue: [
                        LegacyMaskCodingKeys.mask.rawValue: mask.toData().base64EncodedString()
                    ]
                ]
            }
            try container.encode(map)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        let discriminator: Discriminator
        let mask: SecureData?
        switch self {
        case .xormask(let arg):
            discriminator = .xormask
            mask = arg
        case .xorptrpos:
            discriminator = .xorptrpos
            mask = nil
        case .reverse:
            discriminator = .reverse
            mask = nil
        case .obfuscate(let arg):
            discriminator = .obfuscate
            mask = arg
        }
        try container.encode(discriminator, forKey: .type)
        if let mask {
            try container.encode(mask, forKey: .mask)
        }
    }
}

extension OpenVPN.CryptoContainer {
    private static let begin = "-----BEGIN "
    private static let end = "-----END "

    public var isEncrypted: Bool {
        pem.contains("ENCRYPTED")
    }

    public init(pem: String) {
        guard let beginRange = pem.ranges(of: Self.begin).first else {
            self.pem = ""
            return
        }
        self.pem = String(pem[beginRange.lowerBound...])
    }

    public func write(to url: URL) throws {
        try pem.write(toFile: url.filePath(), encoding: .ascii)
    }
}

extension OpenVPN.CryptoContainer: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let pem = try container.decode(String.self)
        self.init(pem: pem)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }
}

extension OpenVPN.CryptoContainer: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? pem : PartoutLogger.redactedValue
    }
}

extension OpenVPN.StaticKey {
    private static let contentLength = 256
    private static let keyCount = 4
    private static let keyLength = OpenVPN.StaticKey.contentLength / OpenVPN.StaticKey.keyCount
    private static let fileHead = "-----BEGIN OpenVPN Static key V1-----"
    private static let fileFoot = "-----END OpenVPN Static key V1-----"
    private static let nonHexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF").inverted

    public var cipherEncryptKey: SecureData {
        guard let direction else {
            fatalError("Direction not set")
        }
        switch direction {
        case .server:
            return key(at: 0)
        case .client:
            return key(at: 2)
        }
    }

    public var cipherDecryptKey: SecureData {
        guard let direction else {
            fatalError("Direction not set")
        }
        switch direction {
        case .server:
            return key(at: 2)
        case .client:
            return key(at: 0)
        }
    }

    public var hmacSendKey: SecureData {
        guard let direction else {
            return key(at: 1)
        }
        switch direction {
        case .server:
            return key(at: 1)
        case .client:
            return key(at: 3)
        }
    }

    public var hmacReceiveKey: SecureData {
        guard let direction else {
            return key(at: 1)
        }
        switch direction {
        case .server:
            return key(at: 3)
        case .client:
            return key(at: 1)
        }
    }

    public init(data: Data, direction: Direction?) {
        precondition(data.count == OpenVPN.StaticKey.contentLength)
        self.init(secureData: SecureData(data), direction: direction)
    }

    public init?(file: String, direction: Direction?) {
        let lines = file.split(separator: "\n")
        self.init(lines: lines, direction: direction)
    }

    public init?(lines: [Substring], direction: Direction?) {
        var isHead = true
        var hexLines: [Substring] = []

        for l in lines {
            if isHead {
                guard !l.hasPrefix("#") else {
                    continue
                }
                guard l == OpenVPN.StaticKey.fileHead else {
                    return nil
                }
                isHead = false
                continue
            }
            guard let first = l.first else {
                return nil
            }
            if first == "-" {
                guard l == OpenVPN.StaticKey.fileFoot else {
                    return nil
                }
                break
            }
            hexLines.append(l)
        }

        let hex = String(hexLines.joined())
        guard hex.count == 2 * OpenVPN.StaticKey.contentLength else {
            return nil
        }
        if hex.rangeOfCharacter(from: OpenVPN.StaticKey.nonHexCharset) != nil {
            return nil
        }
        let data = Data(hex: hex)
        self.init(data: data, direction: direction)
    }

    public init(biData data: Data) {
        self.init(data: data, direction: nil)
    }

    private func key(at: Int) -> SecureData {
        let size = secureData.count / OpenVPN.StaticKey.keyCount
        assert(size == OpenVPN.StaticKey.keyLength)
        return secureData.withOffset(at * size, count: size)
    }

    public var hexString: String {
        secureData.toHex()
    }

    public func asFileContents() -> String {
        let hex = hexString
        let keyLines = stride(from: 0, to: hex.count, by: 32).map { start -> String in
            let begin = hex.index(hex.startIndex, offsetBy: start)
            let end = hex.index(begin, offsetBy: 32, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[begin..<end])
        }
        return ([
            "# 2048 bit OpenVPN static key",
            OpenVPN.StaticKey.fileHead,
        ] + keyLines + [
            OpenVPN.StaticKey.fileFoot
        ]).joined(separator: "\n")
    }
}

extension OpenVPN.TLSWrap {
    public static let clientV2FileHead = "-----BEGIN OpenVPN tls-crypt-v2 client key-----"
    public static let clientV2FileFoot = "-----END OpenVPN tls-crypt-v2 client key-----"

    public init(strategy: Strategy, key: OpenVPN.StaticKey, wrappedKey: SecureData? = nil) {
        precondition(strategy != .cryptV2 || wrappedKey != nil)
        self.strategy = strategy
        self.key = key
        self.wrappedKey = wrappedKey
    }
}

extension OpenVPN.Credentials: Codable {
    enum CodingKeys: CodingKey {
        case username
        case password
        case otp
        case otpMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            username: try container.decode(String.self, forKey: .username),
            password: try container.decode(String.self, forKey: .password),
            otpMethod: try container.decode(OTPMethod.self, forKey: .otpMethod),
            otp: try container.decodeIfPresent(String.self, forKey: .otp)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encoder.shouldEncodeSensitiveData ? username : PartoutLogger.redactedValue, forKey: .username)
        try container.encode(encoder.shouldEncodeSensitiveData ? password : PartoutLogger.redactedValue, forKey: .password)
        try container.encode(otpMethod, forKey: .otpMethod)
        try container.encode(encoder.shouldEncodeSensitiveData ? otp : PartoutLogger.redactedValue, forKey: .otp)
    }
}

extension OpenVPN.Credentials {
    public func builder() -> Builder {
        var builder = Builder()
        builder.username = username
        builder.password = password
        builder.otpMethod = otpMethod
        builder.otp = otp
        return builder
    }

    public var isEmpty: Bool {
        username.isEmpty && password.isEmpty
    }

    public func forAuthentication() throws -> Self {
        try builder().buildForAuthentication()
    }
}

extension OpenVPN.Credentials {
    public struct Builder: Hashable {
        public var username: String
        public var password: String
        public var otpMethod: OTPMethod
        public var otp: String?

        public init(username: String = "", password: String = "", otpMethod: OTPMethod = .none, otp: String? = nil) {
            self.username = username
            self.password = password
            self.otpMethod = otpMethod
            self.otp = otp
        }

        public func build() -> OpenVPN.Credentials {
            OpenVPN.Credentials(username: username, password: password, otpMethod: otpMethod, otp: otp)
        }

        public func buildForAuthentication() throws -> OpenVPN.Credentials {
            OpenVPN.Credentials(
                username: username,
                password: try otpMethod.encoded(with: password, otp: otp),
                otpMethod: .none,
                otp: nil
            )
        }
    }
}

private extension OpenVPN.Credentials.OTPMethod {
    func encoded(with password: String, otp: String?) throws -> String {
        switch self {
        case .none:
            return password
        case .append:
            guard let otp else {
                throw PartoutError(.openVPNOTPRequired)
            }
            return password + otp
        case .encode:
            guard let otp else {
                throw PartoutError(.openVPNOTPRequired)
            }
            let base64Password = password.data(using: .utf8)?.base64EncodedString() ?? ""
            let base64OTP = otp.data(using: .utf8)?.base64EncodedString() ?? ""
            return "SCRV1:\(base64Password):\(base64OTP)"
        }
    }
}

extension OpenVPN.Credentials.OTPMethod {
    private enum LegacyCodingKeys: String, CodingKey {
        case none
        case append
        case encode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(String.self) {
            guard let method = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown OTP method '\(rawValue)'"
                )
            }
            self = method
            return
        }

        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacyContainer.contains(.none) {
            self = .none
        } else if legacyContainer.contains(.append) {
            self = .append
        } else if legacyContainer.contains(.encode) {
            self = .encode
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown legacy OTP method")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private enum OpenVPNConfigurationFallback {
    static let cipher: OpenVPN.Cipher = .aes128cbc
    static let digest: OpenVPN.Digest = .sha1
    static let compressionFraming: OpenVPN.CompressionFraming = .disabled
    static let compressionAlgorithm: OpenVPN.CompressionAlgorithm = .disabled
}

extension OpenVPN.Configuration {
    public var fallbackCipher: Cipher {
        cipher ?? dataCiphers?.first ?? OpenVPNConfigurationFallback.cipher
    }

    public var fallbackDigest: Digest {
        digest ?? OpenVPNConfigurationFallback.digest
    }

    public var fallbackCompressionFraming: CompressionFraming {
        compressionFraming ?? OpenVPNConfigurationFallback.compressionFraming
    }

    public var fallbackCompressionAlgorithm: CompressionAlgorithm {
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

extension OpenVPNModule: Module, BuildableType {
    public static let moduleType: ModuleType = .OpenVPN

    public var isInteractive: Bool {
        if requiresCredentials {
            return true
        }
        return configuration?.staticChallenge ?? requiresInteractiveCredentials ?? false
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            configurationBuilder: configuration?.builder(),
            credentials: credentials,
            isInteractive: requiresInteractiveCredentials ?? false
        )
    }
}

private extension OpenVPNModule {
    var requiresCredentials: Bool {
        guard configuration?.authUserPass == true else {
            return false
        }
        return credentials?.isEmpty ?? true
    }
}

extension OpenVPNModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var configurationBuilder: OpenVPN.Configuration.Builder?
        public var credentials: OpenVPN.Credentials?
        public var isInteractive: Bool

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            configurationBuilder: OpenVPN.Configuration.Builder? = nil,
            credentials: OpenVPN.Credentials? = nil,
            isInteractive: Bool = false
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
            self.credentials = credentials
            self.isInteractive = isInteractive
        }

        public func build() throws -> OpenVPNModule {
            guard configurationBuilder != nil else {
                throw PartoutError(.incompleteModule, self)
            }
            var builder = configurationBuilder
            builder?.staticChallenge = isInteractive
            let configuration = try builder?.build(isClient: true)
            return OpenVPNModule(
                id: id,
                configuration: configuration,
                credentials: credentials,
                requiresInteractiveCredentials: isInteractive
            )
        }
    }
}

extension PartoutError.ModuleField {
    public enum OpenVPN {
        private static let root = "OpenVPN"
        public static let ca = PartoutError.ModuleField("\(root).ca")
        public static let remotes = PartoutError.ModuleField("\(root).remotes")
    }
}
