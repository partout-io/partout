//
//  DNSModule+NE.swift
//  Partout
//
//  Created by Davide De Rosa on 3/26/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NetworkExtension
import PartoutCore

extension DNSModule: NESettingsApplying {
    public func apply(to settings: inout NEPacketTunnelNetworkSettings) {
        var dnsSettings: NEDNSSettings?
        let rawServers = servers.map(\.rawValue)

        switch protocolType {
        case .cleartext:
            if !rawServers.isEmpty {
                dnsSettings = NEDNSSettings(servers: rawServers)
                pp_log(.ne, .info, "\t\tServers: \(servers.map(\.asSensitiveAddress))")
            } else {
                pp_log(.ne, .info, "\t\tServers: empty")
            }

        case .https(let url):
            let specificSettings = NEDNSOverHTTPSSettings(servers: rawServers)
            specificSettings.serverURL = url
            dnsSettings = specificSettings
            pp_log(.ne, .info, "\t\tServers: \(servers.map(\.asSensitiveAddress))")
            pp_log(.ne, .info, "\t\tDoH URL: \(url.absoluteString.asSensitiveAddress)")

        case .tls(let hostname):
            let specificSettings = NEDNSOverTLSSettings(servers: rawServers)
            specificSettings.serverName = hostname
            dnsSettings = specificSettings
            pp_log(.ne, .info, "\t\tServers: \(servers.map(\.asSensitiveAddress))")
            pp_log(.ne, .info, "\t\tDoT hostname: \(hostname.asSensitiveAddress)")
        }

        if dnsSettings != nil {
            domainName.map {
                dnsSettings?.domainName = $0.rawValue
                pp_log(.ne, .info, "\t\tDomain: \($0.asSensitiveAddress)")
            }
            searchDomains.map {
                guard !$0.isEmpty else {
                    return
                }
                dnsSettings?.searchDomains = $0.map(\.rawValue)
                pp_log(.ne, .info, "\t\tSearch domains: \($0.map(\.asSensitiveAddress))")
            }
        } else {
            pp_log(.ne, .info, "\t\tSkip DNS settings")
        }

        settings.dnsSettings = dnsSettings
    }
}
