// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension DNSModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        var dnsSettings: NEDNSSettings?
        let rawServers = servers.map(\.rawValue)

        switch protocolType {
        case .cleartext:
            if !rawServers.isEmpty {
                dnsSettings = NEDNSSettings(servers: rawServers)
                pp_log(ctx, .os, .info, "\t\tServers: \(servers.map { $0.asSensitiveAddress(ctx) })")
            } else {
                pp_log(ctx, .os, .info, "\t\tServers: empty")
            }

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

        if dnsSettings != nil {
            domainName.map {
                dnsSettings?.domainName = $0.rawValue
                pp_log(ctx, .os, .info, "\t\tDomain: \($0.asSensitiveAddress(ctx))")
            }
            searchDomains.map {
                guard !$0.isEmpty else {
                    return
                }
                dnsSettings?.searchDomains = $0.map(\.rawValue)
                pp_log(ctx, .os, .info, "\t\tSearch domains: \($0.map { $0.asSensitiveAddress(ctx) })")
            }
        } else {
            pp_log(ctx, .os, .info, "\t\tSkip DNS settings")
        }

        settings.dnsSettings = dnsSettings
    }
}
