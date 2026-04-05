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
            switch wrap.strategy {
            case .auth:
                append("tls-auth [inline]")
                if let direction = wrap.key.direction {
                    append("key-direction \(direction.rawValue)")
                }
            case .crypt:
                append("tls-crypt [inline]")
            case .cryptV2:
                append("tls-crypt-v2 [inline]")
                appendBlock(tag: tag, contents: wrap.asCryptV2KeyContents())
                return
            }
            appendBlock(tag: tag, contents: wrap.key.asFileContents())
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
        guard !(checksSANHost ?? false) || sanHost != nil else {
            throw PartoutError(.encoding, "OpenVPN SAN host verification requires a hostname")
        }

        append("client")
        append("dev tun")
        append("nobind")
        append("persist-key")
        append("persist-tun")

        if let dataCiphers, !dataCiphers.isEmpty {
            append("data-ciphers \(dataCiphers.map(\.rawValue).joined(separator: ":"))")
            if let cipher {
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
