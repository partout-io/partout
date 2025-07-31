// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

/// Merges local and remote settings.
///
/// OpenVPN settings may be set locally, but may also received from a remote server. This object merges the local and remote ``OpenVPN/Configuration`` into a digestible list of `Module`.
public struct NetworkSettingsBuilder {
    private let ctx: PartoutLoggerContext

    /// The client options.
    private let localOptions: OpenVPN.Configuration

    /// The server options.
    private let remoteOptions: OpenVPN.Configuration

    public init(_ ctx: PartoutLoggerContext, localOptions: OpenVPN.Configuration, remoteOptions: OpenVPN.Configuration) {
        self.ctx = ctx
        self.localOptions = localOptions
        self.remoteOptions = remoteOptions
    }

    /// A list of `Module` mapped from ``localOptions`` and ``remoteOptions``.
    public func modules() -> [Module] {
        pp_log(ctx, .openvpn, .info, "Build modules from local/remote options")

        return [
            ipModule,
            dnsModule,
            httpProxyModule
        ].compactMap { $0 }
    }

    public func print() {
        pp_log(ctx, .openvpn, .notice, "Negotiated options (remote overrides local)")
        if let negCipher = remoteOptions.cipher {
            pp_log(ctx, .openvpn, .notice, "\tCipher: \(negCipher.rawValue)")
        }
        if let negFraming = remoteOptions.compressionFraming {
            pp_log(ctx, .openvpn, .notice, "\tCompression framing: \(negFraming)")
        }
        if let negCompression = remoteOptions.compressionAlgorithm {
            pp_log(ctx, .openvpn, .notice, "\tCompression algorithm: \(negCompression)")
        }
        if let negPing = remoteOptions.keepAliveInterval {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive interval: \(negPing.asTimeString)")
        }
        if let negPingRestart = remoteOptions.keepAliveTimeout {
            pp_log(ctx, .openvpn, .notice, "\tKeep-alive timeout: \(negPingRestart.asTimeString)")
        }

    }
}

// MARK: - Pull

private extension NetworkSettingsBuilder {
    var pullRoutes: Bool {
        !(localOptions.noPullMask?.contains(.routes) ?? false)
    }

    var pullDNS: Bool {
        !(localOptions.noPullMask?.contains(.dns) ?? false)
    }

    var pullProxy: Bool {
        !(localOptions.noPullMask?.contains(.proxy) ?? false)
    }
}

// MARK: - Overall

private extension NetworkSettingsBuilder {
    var isGateway: Bool {
        isIPv4Gateway || isIPv6Gateway
    }

    var routingPolicies: [OpenVPN.RoutingPolicy]? {
        pullRoutes ? (remoteOptions.routingPolicies ?? localOptions.routingPolicies) : localOptions.routingPolicies
    }

    var isIPv4Gateway: Bool {
        routingPolicies?.contains(.IPv4) ?? false
    }

    var isIPv6Gateway: Bool {
        routingPolicies?.contains(.IPv6) ?? false
    }

    var allRoutes4: [Route] {
        var routes = localOptions.routes4 ?? []
        if pullRoutes, let remoteRoutes = remoteOptions.routes4 {
            routes.append(contentsOf: remoteRoutes)
        }
        return routes
    }

    var allRoutes6: [Route] {
        var routes = localOptions.routes6 ?? []
        if pullRoutes, let remoteRoutes = remoteOptions.routes6 {
            routes.append(contentsOf: remoteRoutes)
        }
        return routes
    }

    var allDNSServers: [String] {
        var servers = localOptions.dnsServers ?? []
        if pullDNS, let remoteServers = remoteOptions.dnsServers {
            servers.append(contentsOf: remoteServers)
        }
        return servers
    }

    var dnsDomain: String? {
        var domain = localOptions.dnsDomain
        if pullDNS, let remoteDomain = remoteOptions.dnsDomain {
            domain = remoteDomain
        }
        return domain
    }

    var allDNSSearchDomains: [String] {
        var searchDomains = localOptions.searchDomains ?? []
        if pullDNS, let remoteSearchDomains = remoteOptions.searchDomains {
            searchDomains.append(contentsOf: remoteSearchDomains)
        }
        return searchDomains
    }

    var allProxyBypassDomains: [String] {
        var bypass = localOptions.proxyBypassDomains ?? []
        if pullProxy, let remoteBypass = remoteOptions.proxyBypassDomains {
            bypass.append(contentsOf: remoteBypass)
        }
        return bypass
    }
}

// MARK: - IP

private extension NetworkSettingsBuilder {

    // IPv4/6 address/mask MUST come from server options
    // routes, instead, can both come from server and local options

    var ipModule: Module? {
        let ipv4 = ipv4Settings
        let ipv6 = ipv6Settings
        let mtu: Int?
        if let localMTU = localOptions.mtu, localMTU > 0 {
            mtu = localMTU
        } else {
            mtu = nil
        }
        guard ipv4 != nil || ipv6 != nil || mtu != nil else {
            return nil
        }
        return IPModule.Builder(
            ipv4: ipv4,
            ipv6: ipv6,
            mtu: mtu
        ).tryBuild()
    }

    var ipv4Settings: IPSettings? {
        guard let ipv4 = remoteOptions.ipv4 else {
            return nil
        }
        let defaultRouteGateway = remoteOptions.routeGateway4

        // prepend main server routes
        var computedRoutes = ipv4.includedRoutes + allRoutes4
        if isIPv4Gateway {
            computedRoutes.append(Route(defaultWithGateway: defaultRouteGateway))
        }

        let routes: [Route] = computedRoutes.compactMap { route in
            let ipv4Route = Route(route.destination, route.gateway ?? defaultRouteGateway)
            if let destination = route.destination {
                pp_log(ctx, .openvpn, .info, "\tIPv4: Add route \(destination.description) -> \(route.gateway?.description ?? "*")")
            } else {
                pp_log(ctx, .openvpn, .info, "\tIPv4: Set default gateway -> \(route.gateway?.description ?? "*")")
            }
            return ipv4Route
        }
        return ipv4.including(routes: routes)
    }

    var ipv6Settings: IPSettings? {
        guard let ipv6 = remoteOptions.ipv6 else {
            return nil
        }
        let defaultRouteGateway = remoteOptions.routeGateway6

        // prepend main server routes
        var computedRoutes = ipv6.includedRoutes + allRoutes6
        if isIPv6Gateway {
            computedRoutes.append(Route(defaultWithGateway: defaultRouteGateway))
        }

        let routes = computedRoutes.compactMap { route in
            let ipv6Route = Route(route.destination, route.gateway ?? defaultRouteGateway)
            if let destination = route.destination {
                pp_log(ctx, .openvpn, .info, "\tIPv6: Add route \(destination.description) -> \(route.gateway?.description ?? "*")")
            } else {
                pp_log(ctx, .openvpn, .info, "\tIPv6: Set default gateway -> \(route.gateway?.description ?? "*")")
            }
            return ipv6Route
        }
        return ipv6.including(routes: routes)
    }
}

// MARK: - DNS

private extension NetworkSettingsBuilder {
    private var dnsModule: Module? {
        let dnsServers = allDNSServers
        guard !dnsServers.isEmpty else {
            if isGateway {
                pp_log(ctx, .openvpn, .error, "DNS: No settings provided")
            } else {
                pp_log(ctx, .openvpn, .error, "DNS: No settings provided, use system settings")
            }
            return nil
        }

        pp_log(ctx, .openvpn, .info, "\tDNS: Set servers \(dnsServers.map { $0.asSensitiveAddress(ctx) })")
        var dnsSettings = DNSModule.Builder(servers: dnsServers)

        if let domain = dnsDomain {
            pp_log(ctx, .openvpn, .info, "\tDNS: Set domain: \(domain.asSensitiveAddress(ctx))")
            dnsSettings.domainName = domain
        }

        let searchDomains = allDNSSearchDomains
        if !searchDomains.isEmpty {
            pp_log(ctx, .openvpn, .info, "\tDNS: Set search domains: \(searchDomains.map { $0.asSensitiveAddress(ctx) })")
            dnsSettings.searchDomains = searchDomains
        }

        do {
            return try dnsSettings.tryBuild()
        } catch {
            pp_log(ctx, .openvpn, .error, "DNS: Unable to build settings: \(error)")
            return nil
        }
    }
}

// MARK: - HTTP Proxy

private extension NetworkSettingsBuilder {
    private var httpProxyModule: Module? {
        var proxySettings: HTTPProxyModule.Builder?

        if let httpsProxy = pullProxy ? (remoteOptions.httpsProxy ?? localOptions.httpsProxy) : localOptions.httpsProxy {
            proxySettings = HTTPProxyModule.Builder()
            proxySettings?.secureAddress = httpsProxy.address.rawValue
            proxySettings?.securePort = httpsProxy.port
            pp_log(ctx, .openvpn, .info, "\tHTTPProxy: Set HTTPS proxy \(httpsProxy.asSensitiveAddress(ctx))")
        }
        if let httpProxy = pullProxy ? (remoteOptions.httpProxy ?? localOptions.httpProxy) : localOptions.httpProxy {
            if proxySettings == nil {
                proxySettings = HTTPProxyModule.Builder()
            }
            proxySettings?.address = httpProxy.address.rawValue
            proxySettings?.port = httpProxy.port
            pp_log(ctx, .openvpn, .info, "\tHTTPProxy: Set HTTP proxy \(httpProxy.asSensitiveAddress(ctx))")
        }
        if let pacURL = pullProxy ? (remoteOptions.proxyAutoConfigurationURL ?? localOptions.proxyAutoConfigurationURL) : localOptions.proxyAutoConfigurationURL {
            if proxySettings == nil {
                proxySettings = HTTPProxyModule.Builder()
            }
            proxySettings?.pacURLString = pacURL.absoluteString
            pp_log(ctx, .openvpn, .info, "\tHTTPProxy: Set PAC \(pacURL.absoluteString.asSensitiveAddress(ctx))")
        }

        // only set if there is a proxy (proxySettings set to non-nil above)
        if proxySettings != nil {
            let bypass = allProxyBypassDomains
            if !bypass.isEmpty {
                proxySettings?.bypassDomains = bypass
                pp_log(ctx, .openvpn, .info, "\tHTTPProxy: Set by-pass list: \(bypass.map { $0.asSensitiveAddress(ctx) })")
            }
        }

        do {
            return try proxySettings?.tryBuild()
        } catch {
            pp_log(ctx, .openvpn, .error, "HTTPProxy: Unable to build settings: \(error)")
            return nil
        }
    }
}
