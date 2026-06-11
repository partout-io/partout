// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN.Configuration {
    func asOvpnConfig() throws -> String {
        var lines: [String] = []

        func append(_ line: String) {
            lines.append(line)
        }

        func appendBlock(tag: String, contents: String) {
            lines.append("<\(tag)>")
            lines.append(contents)
            lines.append("</\(tag)>")
        }

        func appendStaticKey(_ wrap: OpenVPN.TLSWrap, tag: String) {
            let blockContents: String
            switch wrap.strategy {
            case .auth:
//                append("tls-auth [inline]")
                if let direction = wrap.key.direction {
                    append("key-direction \(direction.rawValue)")
                }
                blockContents = wrap.key.asFileContents()
            case .crypt:
//                append("tls-crypt [inline]")
                blockContents = wrap.key.asFileContents()
            case .cryptV2:
//                append("tls-crypt-v2 [inline]")
                blockContents = wrap.asCryptV2KeyContents()
            }
            appendBlock(tag: tag, contents: blockContents)
        }

        func appendRoutingPolicies(_ policies: [OpenVPN.RoutingPolicy]) {
            guard !policies.isEmpty else {
                return
            }

            let set = Set(policies)
            var flags: [String] = []
            if !set.contains(.IPv4) {
                flags.append("!ipv4")
            }
            if set.contains(.IPv6) {
                flags.append("ipv6")
            }
            if set.contains(.blockLocal) {
                flags.append("block-local")
            }

            if flags.isEmpty {
                append("redirect-gateway")
            } else {
                append("redirect-gateway \(flags.joined(separator: " "))")
            }
        }

        func routeLine(for route: Route) -> String? {
            guard let destination = route.destination else {
                return nil
            }
            let gateway = route.gateway?.rawValue
            if destination.address.family == .v4 {
                let mask = destination.ipv4Mask
                if let gateway {
                    return "route \(destination.address.rawValue) \(mask) \(gateway)"
                }
                return "route \(destination.address.rawValue) \(mask)"
            }

            if let gateway {
                return "route-ipv6 \(destination.rawValue) \(gateway)"
            }
            return "route-ipv6 \(destination.rawValue)"
        }

        func optionalSeconds(_ interval: TimeInterval?) -> Int? {
            guard let interval, interval > 0 else {
                return nil
            }
            return Int(interval.rounded())
        }

        guard !(staticChallenge ?? false) else {
            throw PartoutError(.encoding, "OpenVPN static challenge export requires challenge text and echo flag")
        }

        append("client")
        append("dev tun")
        append("nobind")
        append("persist-key")
        append("persist-tun")

        if let dataCiphers, !dataCiphers.isEmpty {
            append("data-ciphers \(dataCiphers.map(\.rawValue).joined(separator: ":"))")
            if let cipher {
                // Prefer the explicit modern fallback directive when a
                // negotiated cipher list is present.
                append("data-ciphers-fallback \(cipher.rawValue)")
            }
        } else if let cipher {
            append("cipher \(cipher.rawValue)")
        }

        if let digest {
            append("auth \(digest.rawValue)")
        }

        switch (compressionFraming, compressionAlgorithm) {
        case (.compLZO?, .LZO?):
            append("comp-lzo")
        case (.compLZO?, .disabled?):
            append("comp-lzo no")
        case (.compress?, .LZO?):
            append("compress lzo")
        case (.compress?, .disabled?):
            append("compress stub")
        case (.compressV2?, _):
            append("compress stub-v2")
        default:
            break
        }

        if let keepAliveInterval = optionalSeconds(keepAliveInterval),
           let keepAliveTimeout = optionalSeconds(keepAliveTimeout) {
            append("keepalive \(keepAliveInterval) \(keepAliveTimeout)")
        } else {
            if let keepAliveInterval = optionalSeconds(keepAliveInterval) {
                append("ping \(keepAliveInterval)")
            }
            if let keepAliveTimeout = optionalSeconds(keepAliveTimeout) {
                append("ping-restart \(keepAliveTimeout)")
            }
        }

        if let renegotiatesAfter = optionalSeconds(renegotiatesAfter) {
            append("reneg-sec \(renegotiatesAfter)")
        }

        if checksEKU ?? false {
            append("remote-cert-tls server")
        }
        if checksSANHost ?? false, let sanHost {
            append("verify-x509-name \(sanHost) name")
        }
        if randomizeEndpoint ?? false {
            append("remote-random")
        }
        if randomizeHostnames ?? false {
            append("remote-random-hostname")
        }
        if let mtu {
            append("tun-mtu \(mtu)")
        }

        if let remotes {
            for remote in remotes {
                append("remote \(remote.address.rawValue) \(remote.proto.port) \(remote.proto.socketType.rawValue.lowercased())")
            }
        }

        if authUserPass ?? false {
            append("auth-user-pass")
        }

        if let authToken {
            append("auth-token \(authToken)")
        }
        if let peerId {
            append("peer-id \(peerId)")
        }

        if let routingPolicies {
            appendRoutingPolicies(routingPolicies)
        }

        if let routeGateway4 {
            append("route-gateway \(routeGateway4.rawValue)")
        }
        if let routeGateway6 {
            append("route-ipv6-gateway \(routeGateway6.rawValue)")
        }

        if let dnsServers, !dnsServers.isEmpty {
            for server in dnsServers {
                append("dhcp-option DNS \(server)")
            }
        }
        if let dnsDomain {
            append("dhcp-option DOMAIN \(dnsDomain)")
        }
        if let searchDomains, !searchDomains.isEmpty {
            for domain in searchDomains {
                append("dhcp-option DOMAIN-SEARCH \(domain)")
            }
        }
        if let httpProxy {
            append("dhcp-option PROXY_HTTP \(httpProxy.address.rawValue) \(httpProxy.port)")
        }
        if let httpsProxy {
            append("dhcp-option PROXY_HTTPS \(httpsProxy.address.rawValue) \(httpsProxy.port)")
        }
        if let proxyAutoConfigurationURL {
            append("dhcp-option PROXY_AUTO_CONFIG_URL \(proxyAutoConfigurationURL.absoluteString)")
        }
        if let proxyBypassDomains, !proxyBypassDomains.isEmpty {
            append("dhcp-option PROXY_BYPASS \(proxyBypassDomains.joined(separator: " "))")
        }

        if let routes4 {
            for route in routes4 {
                if let line = routeLine(for: route) {
                    append(line)
                }
            }
        }
        if let routes6 {
            for route in routes6 {
                if let line = routeLine(for: route) {
                    append(line)
                }
            }
        }

        if let xorMethod {
            switch xorMethod {
            case .xormask(let mask):
                guard let maskString = String(data: mask.toData(), encoding: .utf8) else {
                    throw PartoutError(.encoding, "OpenVPN scramble mask must be UTF-8")
                }
                append("scramble xormask \(maskString)")
            case .xorptrpos:
                append("scramble xorptrpos")
            case .reverse:
                append("scramble reverse")
            case .obfuscate(let mask):
                guard let maskString = String(data: mask.toData(), encoding: .utf8) else {
                    throw PartoutError(.encoding, "OpenVPN scramble mask must be UTF-8")
                }
                append("scramble obfuscate \(maskString)")
            }
        }

        if let ca {
            appendBlock(tag: "ca", contents: ca.pem)
        }
        if let clientCertificate {
            appendBlock(tag: "cert", contents: clientCertificate.pem)
        }
        if let clientKey {
            appendBlock(tag: "key", contents: clientKey.pem)
        }
        if let tlsWrap {
            switch tlsWrap.strategy {
            case .auth:
                appendStaticKey(tlsWrap, tag: "tls-auth")
            case .crypt:
                appendStaticKey(tlsWrap, tag: "tls-crypt")
            case .cryptV2:
                appendStaticKey(tlsWrap, tag: "tls-crypt-v2")
            }
        }

        return lines.joined(separator: "\n")
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
