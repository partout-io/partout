// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension StandardOpenVPNParser {
    struct Builder {
        private let supportsLZO: Bool
        private let decrypter: KeyDecrypter?

        private var optDataCiphers: [OpenVPN.Cipher]?
        private var optDataCiphersFallback: OpenVPN.Cipher?
        private var optCipher: OpenVPN.Cipher?
        private var optDigest: OpenVPN.Digest?
        private var optCompressionFraming: OpenVPN.CompressionFraming?
        private var optCompressionAlgorithm: OpenVPN.CompressionAlgorithm?
        private var optCA: OpenVPN.CryptoContainer?
        private var optClientCertificate: OpenVPN.CryptoContainer?
        private var optClientKey: OpenVPN.CryptoContainer?
        private var optKeyDirection: OpenVPN.StaticKey.Direction?
        private var optTLSKeyLines: [Substring]?
        private var optTLSStrategy: OpenVPN.TLSWrap.Strategy?
        private var optKeepAliveSeconds: TimeInterval?
        private var optKeepAliveTimeoutSeconds: TimeInterval?
        private var optRenegotiateAfterSeconds: TimeInterval?
        private var optCredentials: OpenVPN.Credentials?
        //
        private var optDefaultProto: IPSocketType?
        private var optDefaultPort: UInt16?
        private var optRemotes: [RemoteGroup] = []
        private var authUserPass = false
        private var staticChallenge = false
        private var optChecksEKU: Bool?
        private var optRandomizeEndpoint: Bool?
        private var optRandomizeHostnames: Bool?
        private var optMTU: Int?
        //
        private var optAuthToken: String?
        private var optPeerId: UInt32?
        //
        private var optTopology: String?
        private var optIfconfig4Arguments: [String]?
        private var optIfconfig6Arguments: [String]?
        private var optGateway4Arguments: [String]?
        private var optRoutes4: [Route4Group]?
        private var optRoutes6: [Route6Group]?
        private var optDNSServers: [String]?
        private var optDomain: String?
        private var optSearchDomains: [String]?
        private var optHTTPProxy: Endpoint?
        private var optHTTPSProxy: Endpoint?
        private var optProxyAutoConfigurationURL: URL?
        private var optProxyBypass: [String]?
        private var optRedirectGateway: Set<RedirectGateway>?
        private var optRouteNoPull: Bool?
        //
        private var optXorMethod: OpenVPN.ObfuscationMethod?

        private var optWarning: StandardOpenVPNParserError?
        private var currentBlockName: String?
        private var currentBlock: [String] = []

        init(supportsLZO: Bool, decrypter: KeyDecrypter?) {
            self.supportsLZO = supportsLZO
            self.decrypter = decrypter
        }
    }
}

// MARK: - Parsing

extension StandardOpenVPNParser.Builder {

    @inlinable
    mutating func putOption(_ option: OpenVPN.Option, line: String, components: [String]) throws {
        switch option {

            // MARK: Unsupported

        case .connectionBlock:
            throw StandardOpenVPNParserError.unsupportedConfiguration(option: "<connection> blocks")
        case .fragment:
            throw StandardOpenVPNParserError.unsupportedConfiguration(option: "fragment")
        case .connectionProxy:
            throw StandardOpenVPNParserError.unsupportedConfiguration(option: "proxy: \"\(line)\"")
        case .externalFiles:
            throw StandardOpenVPNParserError.unsupportedConfiguration(option: "external file: \"\(line)\"")
        case .tlsCryptV2:
            throw StandardOpenVPNParserError.unsupportedConfiguration(option: "tls-crypt-v2")

            // MARK: Continuation

        case .continuation:
            guard components[1] != "2" else {
                throw StandardOpenVPNParserError.continuationPushReply
            }

            // MARK: Inline content

        case .blockBegin:
            if currentBlockName == nil {
                guard let tag = components.first else {
                    break
                }
                let from = tag.index(after: tag.startIndex)
                let to = tag.index(before: tag.endIndex)

                currentBlockName = String(tag[from..<to])
                currentBlock = []
            }

        case .blockEnd:
            guard let tag = components.first else {
                break
            }
            let from = tag.index(tag.startIndex, offsetBy: 2)
            let to = tag.index(before: tag.endIndex)

            let blockName = String(tag[from..<to])
            guard blockName == currentBlockName else {
                break
            }

            // first is opening tag
            switch blockName {
            case "auth-user-pass":
                guard !currentBlock.isEmpty else {
                    break
                }
                let username = currentBlock[0]
                let password = currentBlock.count > 1 ? currentBlock[1] : ""
                optCredentials = OpenVPN.Credentials.Builder(username: username, password: password).build()

            case "ca":
                optCA = OpenVPN.CryptoContainer(pem: currentBlock.joined(separator: "\n"))

            case "cert":
                optClientCertificate = OpenVPN.CryptoContainer(pem: currentBlock.joined(separator: "\n"))

            case "key":
                normalizeEncryptedPEMBlock(block: &currentBlock)
                optClientKey = OpenVPN.CryptoContainer(pem: currentBlock.joined(separator: "\n"))

            case "tls-auth":
                optTLSKeyLines = currentBlock.map(Substring.init(_:))
                optTLSStrategy = .auth

            case "tls-crypt":
                optTLSKeyLines = currentBlock.map(Substring.init(_:))
                optTLSStrategy = .crypt

            default:
                break
            }
            currentBlockName = nil
            currentBlock = []

            // MARK: General

        case .cipher:
            let rawValue = components[1]
            optCipher = OpenVPN.Cipher(rawValue: rawValue.uppercased())

        case .dataCiphers:
            let rawValue = components[1]
            let rawCiphers = rawValue.components(separatedBy: ":")
            optDataCiphers = rawCiphers.compactMap {
                OpenVPN.Cipher(rawValue: $0.uppercased())
            }

        case .dataCiphersFallback:
            let rawValue = components[1]
            optDataCiphersFallback = OpenVPN.Cipher(rawValue: rawValue.uppercased())

        case .auth:
            let rawValue = components[1]
            optDigest = OpenVPN.Digest(rawValue: rawValue.uppercased())
            if optDigest == nil {
                throw StandardOpenVPNParserError.unsupportedConfiguration(option: "auth \(rawValue)")
            }

        case .compLZO:
            optCompressionFraming = .compLZO

            if supportsLZO {
                let arg = components.last
                optCompressionAlgorithm = (arg == "no") ? .disabled : .LZO
            } else {
                guard components.count > 1, components[1] == "no" else {
                    throw StandardOpenVPNParserError.unsupportedConfiguration(option: line)
                }
                optCompressionAlgorithm = .disabled
            }

        case .compress:
            optCompressionFraming = .compress

            if components.count == 2, let arg = components.last {
                switch arg {
                case "lzo":
                    guard supportsLZO else {
                        throw StandardOpenVPNParserError.unsupportedConfiguration(option: line)
                    }
                    optCompressionAlgorithm = .LZO

                case "stub":
                    optCompressionAlgorithm = .disabled

                case "stub-v2":
                    optCompressionFraming = .compressV2
                    optCompressionAlgorithm = .disabled

                default:
                    throw StandardOpenVPNParserError.unsupportedConfiguration(option: line)
                }
            } else {
                optCompressionAlgorithm = .disabled
            }

        case .keyDirection:
            guard components.count == 2, let arg = components.last,
                  let value = Int(arg) else {
                break
            }
            optKeyDirection = OpenVPN.StaticKey.Direction(rawValue: value)

        case .ping:
            guard components.count == 2, let arg = components.last else {
                break
            }
            optKeepAliveSeconds = TimeInterval(arg)

        case .pingRestart:
            guard components.count == 2, let arg = components.last else {
                break
            }
            optKeepAliveTimeoutSeconds = TimeInterval(arg)

        case .keepAlive:
            guard components.count == 3 else {
                break
            }
            let ping = components[1]
            let pingRestart = components[2]
            optKeepAliveSeconds = TimeInterval(ping)
            optKeepAliveTimeoutSeconds = TimeInterval(pingRestart)

        case .renegSec:
            guard components.count == 2 else {
                break
            }
            let arg = components[1]
            optRenegotiateAfterSeconds = TimeInterval(arg)

            // MARK: Client

        case .proto:
            guard components.count == 2 else {
                break
            }
            let str = components[1]
            optDefaultProto = IPSocketType(protoString: str)
            if optDefaultProto == nil {
                throw StandardOpenVPNParserError.unsupportedConfiguration(option: "proto \(str)")
            }

        case .port:
            guard components.count == 2 else {
                break
            }
            let str = components[1]
            optDefaultPort = UInt16(str)

        case .remote:
            guard components.count > 1 else {
                break
            }
            let hostname = components[1]
            var port: UInt16?
            var proto: IPSocketType?
            if components.count > 2 {
                port = UInt16(components[2])
            }
            if components.count > 3 {
                proto = IPSocketType(protoString: components[3])
            }
            optRemotes.append((hostname, port, proto))

        case .eku:
            optChecksEKU = true

        case .remoteRandom:
            optRandomizeEndpoint = true

        case .remoteRandomHostname:
            optRandomizeHostnames = true

        case .mtu:
            guard components.count == 2 else {
                break
            }
            let str = components[1]
            optMTU = Int(str)

        case .authUserPass:
            authUserPass = true

        case .staticChallenge:
            staticChallenge = true

            // MARK: Server

        case .authToken:
            guard components.count == 2 else {
                break
            }
            optAuthToken = components[1]

        case .peerId:
            guard components.count == 2 else {
                break
            }
            optPeerId = UInt32(components[1])

            // MARK: Routing

        case .topology:
            guard components.count == 2 else {
                break
            }
            optTopology = components[1]

        case .ifconfig:
            guard components.count > 1 else {
                break
            }
            var args = components
            args.removeFirst()
            optIfconfig4Arguments = args

        case .ifconfig6:
            guard components.count > 1 else {
                break
            }
            var args = components
            args.removeFirst()
            optIfconfig6Arguments = args

        case .route:
            var args = components
            args.removeFirst()
            let routeEntryArguments = args

            let address = routeEntryArguments[0]
            let mask = (routeEntryArguments.count > 1) ? routeEntryArguments[1] : "255.255.255.255"
            var gateway = (routeEntryArguments.count > 2) ? routeEntryArguments[2] : nil // defaultGateway4
            if gateway == "vpn_gateway" {
                gateway = nil
            }
            if optRoutes4 == nil {
                optRoutes4 = []
            }
            optRoutes4?.append((address, mask, gateway))

        case .route6:
            var args = components
            args.removeFirst()
            let routeEntryArguments = args

            let destinationComponents = routeEntryArguments[0].components(separatedBy: "/")
            guard destinationComponents.count == 2 else {
                break
            }
            guard let prefix = Int(destinationComponents[1]) else {
                break
            }

            let destination = destinationComponents[0]
            var gateway = (routeEntryArguments.count > 1) ? routeEntryArguments[1] : nil // defaultGateway6
            if gateway == "vpn_gateway" {
                gateway = nil
            }
            if optRoutes6 == nil {
                optRoutes6 = []
            }
            optRoutes6?.append((destination, prefix, gateway))

        case .gateway:
            var args = components
            args.removeFirst()
            optGateway4Arguments = args

        case .dns:
            guard components.count == 3 else {
                break
            }
            if optDNSServers == nil {
                optDNSServers = []
            }
            optDNSServers?.append(components[2])

        case .domain:
            guard components.count == 3 else {
                break
            }
            optDomain = components[2]

        case .domainSearch:
            guard components.count == 3 else {
                break
            }
            if optSearchDomains == nil {
                optSearchDomains = []
            }
            optSearchDomains?.append(components[2])

        case .proxy:
            if components.count == 3 {
                guard let url = URL(string: components[2]) else {
                    throw StandardOpenVPNParserError.malformed(option: "dhcp-option PROXY_AUTO_CONFIG_URL has malformed URL")
                }
                optProxyAutoConfigurationURL = url
                break
            }

            guard components.count == 4, let port = UInt16(components[3]) else {
                break
            }
            switch components[1] {
            case "PROXY_HTTPS":
                do {
                    optHTTPSProxy = try Endpoint(components[2], port)
                } catch {
                    throw StandardOpenVPNParserError.malformed(option: "dhcp-option PROXY_HTTPS")
                }

            case "PROXY_HTTP":
                do {
                    optHTTPProxy = try Endpoint(components[2], port)
                } catch {
                    throw StandardOpenVPNParserError.malformed(option: "dhcp-option PROXY_HTTPS")
                }

            default:
                break
            }

        case .proxyBypass:
            var args = components
            guard args.count > 2 else {
                return
            }
            args.removeFirst(2)
            optProxyBypass = args

        case .redirectGateway:

            // redirect IPv4 by default
            optRedirectGateway = [.def1]

            var args = components
            args.removeFirst()
            optRedirectGateway?.formUnion(Set(args.compactMap {
                RedirectGateway(rawValue: $0)
            }))

        case .routeNoPull:
            optRouteNoPull = true

            // MARK: Extra

        case .xorInfo:
            guard components.count > 1 else {
                break
            }

            switch components[1] {
            case "xormask":
                if components.count > 2, let mask = SecureData(components[2]) {
                    optXorMethod = .xormask(mask: mask)
                }

            case "xorptrpos":
                optXorMethod = .xorptrpos

            case "reverse":
                optXorMethod = .reverse

            case "obfuscate":
                if components.count > 2, let mask = SecureData(components[2]) {
                    optXorMethod = .obfuscate(mask: mask)
                }

            default:
                break
            }
        }
    }

    mutating func putLine(_ line: String) {
        if currentBlockName != nil {
            currentBlock.append(line)
        }
    }
}

// MARK: - Building

extension StandardOpenVPNParser.Builder {
    func build(isClient: Bool, passphrase: String?) throws -> StandardOpenVPNParser.Result {

        // ensure that non-nil network settings also imply non-empty
        if let array = optRoutes4 {
            assert(!array.isEmpty)
        }
        if let array = optRoutes6 {
            assert(!array.isEmpty)
        }
        if let array = optDNSServers {
            assert(!array.isEmpty)
        }
        if let array = optSearchDomains {
            assert(!array.isEmpty)
        }
        if let array = optProxyBypass {
            assert(!array.isEmpty)
        }

        //

        var builder = OpenVPN.Configuration.Builder()

        // MARK: General

        builder.cipher = optDataCiphersFallback ?? optCipher
        builder.dataCiphers = optDataCiphers
        builder.digest = optDigest
        builder.compressionFraming = optCompressionFraming
        builder.compressionAlgorithm = optCompressionAlgorithm
        builder.ca = optCA
        builder.clientCertificate = optClientCertificate
        builder.authUserPass = authUserPass
        builder.staticChallenge = staticChallenge

        if let clientKey = optClientKey, clientKey.isEncrypted {
            guard let passphrase, !passphrase.isEmpty else {
                throw StandardOpenVPNParserError.encryptionPassphrase
            }
            do {
                guard let decrypter else {
                    throw StandardOpenVPNParserError.decrypterRequired
                }
                builder.clientKey = try clientKey.decrypted(with: decrypter, passphrase: passphrase)
            } catch {
                throw StandardOpenVPNParserError.unableToDecrypt(error: error)
            }
        } else {
            builder.clientKey = optClientKey
        }

        if let keyLines = optTLSKeyLines, let strategy = optTLSStrategy {
            let optKey: OpenVPN.StaticKey?
            switch strategy {
            case .auth:
                optKey = OpenVPN.StaticKey(lines: keyLines, direction: optKeyDirection)

            case .crypt:
                optKey = OpenVPN.StaticKey(lines: keyLines, direction: .client)

            @unknown default:
                optKey = nil
            }
            if let key = optKey {
                builder.tlsWrap = OpenVPN.TLSWrap(strategy: strategy, key: key)
            }
        }

        builder.keepAliveInterval = optKeepAliveSeconds
        builder.keepAliveTimeout = optKeepAliveTimeoutSeconds
        builder.renegotiatesAfter = optRenegotiateAfterSeconds

        // MARK: Client

        let optDefaultProto = optDefaultProto ?? .udp
        let optDefaultPort = optDefaultPort ?? 1194
        if !optRemotes.isEmpty {
            var fullRemotes: [FullRemoteGroup] = []
            optRemotes.forEach {
                let hostname = $0.0
                let port = $0.1 ?? optDefaultPort
                let socketType = $0.2 ?? optDefaultProto
                fullRemotes.append((hostname, port, socketType))
            }
            builder.remotes = try fullRemotes.map {
                try ExtendedEndpoint($0.address, .init($0.socket, $0.port))
            }
        }

        builder.authUserPass = authUserPass
        builder.checksEKU = optChecksEKU
        builder.randomizeEndpoint = optRandomizeEndpoint
        builder.randomizeHostnames = optRandomizeHostnames
        builder.mtu = optMTU

        // MARK: Server

        builder.authToken = optAuthToken
        builder.peerId = optPeerId

        // MARK: Routing

        //
        // excerpts from OpenVPN manpage
        //
        // "--ifconfig l rn":
        //
        // Set  TUN/TAP  adapter parameters.  l is the IP address of the local VPN endpoint.  For TUN devices in point-to-point mode, rn is the IP address of
        // the remote VPN endpoint.  For TAP devices, or TUN devices used with --topology subnet, rn is the subnet mask of the virtual network segment  which
        // is being created or connected to.
        //
        // "--topology mode":
        //
        // Note: Using --topology subnet changes the interpretation of the arguments of --ifconfig to mean "address netmask", no longer "local remote".
        //
        let defaultGateway4: String?
        if let ifconfig4Arguments = optIfconfig4Arguments {
            guard ifconfig4Arguments.count == 2 else {
                throw StandardOpenVPNParserError.malformed(option: "ifconfig takes 2 arguments")
            }

            let address4: String
            let vpnMask4: String

            let topology = Topology(rawValue: optTopology ?? "") ?? .net30
            switch topology {
            case .subnet:

                // default gateway required when topology is subnet
                guard let gateway4Arguments = optGateway4Arguments, gateway4Arguments.count == 1 else {
                    throw StandardOpenVPNParserError.malformed(option: "route-gateway takes 1 argument")
                }
                address4 = ifconfig4Arguments[0]
                vpnMask4 = ifconfig4Arguments[1]
                defaultGateway4 = gateway4Arguments[0]

            case .net30:
                address4 = ifconfig4Arguments[0]
                vpnMask4 = "255.255.255.252"
                defaultGateway4 = ifconfig4Arguments[1]

            case .p2p:
                throw StandardOpenVPNParserError.unsupportedConfiguration(option: "topology p2p")
            }

            let vpnAddress4 = try Subnet(address4, vpnMask4)
            var includedRoutes: [Route] = []
            if let vpnNetwork4 = vpnAddress4.address.network(with: vpnMask4) {
                let vpnDestination4 = try Subnet(vpnNetwork4.rawValue, vpnMask4)
                includedRoutes.append(Route(vpnDestination4, nil))
            }

            builder.ipv4 = IPSettings(subnet: vpnAddress4)
                .including(routes: includedRoutes)
        } else {
            defaultGateway4 = nil
        }
        builder.routes4 = try optRoutes4?.compactMap { tuple in
            let subnet = try Subnet(tuple.address, tuple.netmask)
            let gateway = tuple.gateway.map(Address.init(rawValue:)) ?? nil
            return Route(subnet, gateway)
        }
        builder.routeGateway4 = defaultGateway4.map(Address.init(rawValue:)) ?? nil

        let defaultGateway6: String?
        if let ifconfig6Arguments = optIfconfig6Arguments {
            guard ifconfig6Arguments.count == 2 else {
                throw StandardOpenVPNParserError.malformed(option: "ifconfig-ipv6 takes 2 arguments")
            }
            let address6Components = ifconfig6Arguments[0].components(separatedBy: "/")
            guard address6Components.count == 2 else {
                throw StandardOpenVPNParserError.malformed(option: "ifconfig-ipv6 address must have a /prefix")
            }
            guard let vpnPrefix6 = Int(address6Components[1]) else {
                throw StandardOpenVPNParserError.malformed(option: "ifconfig-ipv6 address prefix must be a 8-bit number")
            }

            let address6 = address6Components[0]
            defaultGateway6 = ifconfig6Arguments[1]

            let vpnAddress6 = try Subnet(address6, vpnPrefix6)
            var includedRoutes: [Route] = []
            if let vpnNetwork6 = vpnAddress6.address.network(with: vpnPrefix6) {
                let vpnDestination6 = try Subnet(vpnNetwork6.rawValue, vpnPrefix6)
                includedRoutes.append(Route(vpnDestination6, nil))
            }

            builder.ipv6 = IPSettings(subnet: vpnAddress6)
                .including(routes: includedRoutes)
        } else {
            defaultGateway6 = nil
        }
        builder.routes6 = try optRoutes6?.compactMap { tuple in
            let subnet = try Subnet(tuple.destination, tuple.prefix)
            let gateway = tuple.gateway.map(Address.init(rawValue:)) ?? nil
            return Route(subnet, gateway)
        }
        builder.routeGateway6 = defaultGateway6.map(Address.init(rawValue:)) ?? nil

        builder.dnsServers = optDNSServers
        builder.dnsDomain = optDomain
        builder.searchDomains = optSearchDomains
        builder.httpProxy = optHTTPProxy
        builder.httpsProxy = optHTTPSProxy
        builder.proxyAutoConfigurationURL = optProxyAutoConfigurationURL
        builder.proxyBypassDomains = optProxyBypass
        if optRouteNoPull ?? false {
            builder.noPullMask = [.routes, .dns, .proxy]
        }

        if let flags = optRedirectGateway {
            var policies: Set<OpenVPN.RoutingPolicy> = []
            for opt in flags {
                switch opt {
                case .def1:
                    policies.insert(.IPv4)

                case .ipv6:
                    policies.insert(.IPv6)

                case .blockLocal:
                    policies.insert(.blockLocal)

                default:
                    // XXX: handle [auto]local and block-*
                    continue
                }
            }
            if flags.contains(.noIPv4) {
                policies.remove(.IPv4)
            }
            builder.routingPolicies = Array(policies)
        }

        // MARK: Extra

        builder.xorMethod = optXorMethod

        //

        let configuration = try builder.tryBuild(isClient: isClient)
        return StandardOpenVPNParser.Result(
            url: nil,
            configuration: configuration,
            credentials: optCredentials,
            warning: optWarning
        )
    }
}

// MARK: -

// swiftlint:disable large_tuple
private extension StandardOpenVPNParser.Builder {
    enum Topology: String {
        case net30

        @available(*, deprecated, message: "Removed in 2.5.0")
        case p2p

        case subnet
    }

    enum RedirectGateway: String {
        case def1 // default

        case noIPv4 = "!ipv4"

        case ipv6

        case local

        case autolocal

        case blockLocal = "block-local"

        case bypassDHCP = "bypass-dhcp"

        case bypassDNS = "bypass-dns"
    }

    typealias RemoteGroup = (address: String, port: UInt16?, socket: IPSocketType?)

    typealias FullRemoteGroup = (address: String, port: UInt16, socket: IPSocketType)

    typealias Route4Group = (address: String, netmask: String, gateway: String?)

    typealias Route6Group = (destination: String, prefix: Int, gateway: String?)
}
// swiftlint:enable large_tuple

private extension IPSocketType {
    init?(protoString: String) {
        self.init(rawValue: protoString.uppercased())
    }
}

private func normalizeEncryptedPEMBlock(block: inout [String]) {
//    if block.count >= 1 && block[0].contains("ENCRYPTED") {
//        return true
//    }

    // XXX: restore blank line after encryption header (easier than tweaking trimmedLines)
    if block.count >= 3 && block[1].contains("Proc-Type") {
        block.insert("", at: 3)
//        return true
    }
//    return false
}
