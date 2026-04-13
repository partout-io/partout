// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension DNSModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        let dnsSettings: NEDNSSettings
        let rawDomains: [String]

        // Reuse DNS settings from VPN if desired (and if any)
        if inheritsVPN == true, let currentDNSSettings = settings.dnsSettings {
            dnsSettings = currentDNSSettings

            // Reuse search domains for matching
            rawDomains = dnsSettings.searchDomains ?? []
        } else {
            let rawServers = servers.map(\.rawValue)
            rawDomains = searchDomains?.map(\.rawValue) ?? []

            // Former DNS settings are always overridden, even with empty servers
            switch protocolType {
            case .cleartext:
                guard !rawServers.isEmpty else {
                    pp_log(ctx, .os, .error, "\t\tSkip DNS settings, cleartext requires non-empty servers")
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
        }

        // Apply domains with the given policy
        let domainsDescription = rawDomains.map { $0.asSensitiveAddress(ctx) }
        let searchDomains = rawDomains
        //
        // Credit for .matchDomains:
        // https://github.com/WireGuard/wireguard-apple/pull/11
        //
        if dnsSettings.dnsProtocol == .cleartext {
            switch domainPolicy {
            case .match:
                let matchDomains = !searchDomains.isEmpty ? searchDomains : [""]
                dnsSettings.searchDomains = nil
                dnsSettings.matchDomains = matchDomains
                dnsSettings.matchDomainsNoSearch = true
                pp_log(ctx, .os, .info, "\t\tMatch-only domains: \(domainsDescription)")
            case .matchAndSearch:
                let matchDomains = !searchDomains.isEmpty ? searchDomains : [""]
                dnsSettings.searchDomains = searchDomains
                dnsSettings.matchDomains = matchDomains
                dnsSettings.matchDomainsNoSearch = false
                pp_log(ctx, .os, .info, "\t\tMatch/Search domains: \(domainsDescription)")
            default:
                // XXX: .searchDomains is ineffective when the VPN is not the default
                // gateway. Appending .searchDomains to .matchDomains would be a partial
                // workaround, but this is essentially a bug in Network Extension.
                dnsSettings.searchDomains = searchDomains
                dnsSettings.matchDomains = [""]
                dnsSettings.matchDomainsNoSearch = false
                pp_log(ctx, .os, .info, "\t\tSearch-only domains: \(domainsDescription)")
            }
        } else if !rawDomains.isEmpty {
            //
            // This is why we guard before committing .matchDomains:
            // https://git.zx2c4.com/wireguard-apple/commit/?id=20bdf46792905de8862ae7641e50e0f9f99ec946
            //
            // XXX: Network Extension seems to ignore domains completely
            // when DNS is configured to use DoH/DoT
            pp_log(ctx, .os, .error, "\t\tSkip DNS match/search domains, ignored in DoH/DoT")
            dnsSettings.searchDomains = nil
            dnsSettings.matchDomains = nil
        }

        // Commit to tunnel settings
        settings.dnsSettings = dnsSettings
    }
}
