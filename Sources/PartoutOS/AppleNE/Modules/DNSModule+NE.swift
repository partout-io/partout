// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension DNSModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        let dnsSettings: NEDNSSettings
        let rawServers = servers.map(\.rawValue)

        // Former DNS settings are always overridden, even with empty servers
        switch protocolType {
        case .cleartext:
            guard !rawServers.isEmpty else {
                pp_log(ctx, .os, .info, "\t\tSkip DNS settings, cleartext requires non-empty servers")
                return
            }
            dnsSettings = NEDNSSettings(servers: rawServers)
            pp_log(ctx, .os, .info, "\t\tServers: \(servers.map { $0.asSensitiveAddress(ctx) })")
        case .https(let url):
            let specificSettings = NEDNSOverHTTPSSettings(servers: rawServers)
            specificSettings.serverURL = url
            dnsSettings = specificSettings
            pp_log(ctx, .os, .info, "\t\tServers: \(servers.map { $0.asSensitiveAddress(ctx) })")
            pp_log(ctx, .os, .info, "\t\tDoH URL: \(url.absoluteString.asSensitiveAddress(ctx))")
        case .tls(let hostname):
            let specificSettings = NEDNSOverTLSSettings(servers: rawServers)
            specificSettings.serverName = hostname
            dnsSettings = specificSettings
            pp_log(ctx, .os, .info, "\t\tServers: \(servers.map { $0.asSensitiveAddress(ctx) })")
            pp_log(ctx, .os, .info, "\t\tDoT hostname: \(hostname.asSensitiveAddress(ctx))")
        @unknown default:
            break
        }

        // Main domain (if set)
        domainName.map {
            dnsSettings.domainName = $0.rawValue
            pp_log(ctx, .os, .info, "\t\tDomain: \($0.asSensitiveAddress(ctx))")
        }

        // Apply domains with the given policy
        let domains = searchDomains ?? []
        let domainsDescription = domains.map { $0.asSensitiveAddress(ctx) }
        let searchDomains = domains.map(\.rawValue)
        //
        // Credit for .matchDomains:
        // https://github.com/WireGuard/wireguard-apple/pull/11
        //
        switch domainPolicy {
        case .search:
            dnsSettings.searchDomains = searchDomains
            // XXX: This works around a Network Extension bug. We add the
            // search domains here because .searchDomains is ineffective when
            // the VPN is not the default gateway
            dnsSettings.matchDomains = [""] + searchDomains
            dnsSettings.matchDomainsNoSearch = false
            pp_log(ctx, .os, .info, "\t\tSearch-only domains: \(domainsDescription)")
        case .match:
            let matchDomains = !searchDomains.isEmpty ? searchDomains : [""]
            dnsSettings.searchDomains = nil
            dnsSettings.matchDomains = matchDomains
            dnsSettings.matchDomainsNoSearch = true
            pp_log(ctx, .os, .info, "\t\tMatch-only domains: \(domainsDescription)")
        default:
            let matchDomains = !searchDomains.isEmpty ? searchDomains : [""]
            dnsSettings.searchDomains = searchDomains
            dnsSettings.matchDomains = matchDomains
            dnsSettings.matchDomainsNoSearch = false
            pp_log(ctx, .os, .info, "\t\tMatch/Search domains: \(domainsDescription)")
        }

        //
        // This is why we guard before committing .matchDomains:
        // https://git.zx2c4.com/wireguard-apple/commit/?id=20bdf46792905de8862ae7641e50e0f9f99ec946
        //
        assert(dnsSettings.matchDomains != nil)
        if dnsSettings.servers.isEmpty {
            pp_log(ctx, .os, .error, "\t\tIgnoring match domains without bootstrap DNS servers")
            dnsSettings.matchDomains = nil
        }

        // Commit to tunnel settings
        settings.dnsSettings = dnsSettings
    }
}
