//
//  HTTPProxyModule+NE.swift
//  Partout
//
//  Created by Davide De Rosa on 12/29/23.
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

extension HTTPProxyModule: NESettingsApplying {
    public func apply(to settings: inout NEPacketTunnelNetworkSettings) {
        let proxySettings = NEProxySettings()

        proxy.map {
            proxySettings.httpEnabled = true
            proxySettings.httpServer = $0.neProxy
            pp_log(.ne, .info, "\t\tHTTP server: \($0.asSensitiveAddress)")
        }
        secureProxy.map {
            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = $0.neProxy
            pp_log(.ne, .info, "\t\tHTTPS server: \($0.asSensitiveAddress)")
        }
        pacURL.map {
            proxySettings.autoProxyConfigurationEnabled = true
            proxySettings.proxyAutoConfigurationURL = $0
            pp_log(.ne, .info, "\t\tPAC URL: \($0.absoluteString.asSensitiveAddress)")
        }
        proxySettings.exceptionList = bypassDomains.map(\.rawValue)
        pp_log(.ne, .info, "\t\tBypass domains: \(bypassDomains.map(\.asSensitiveAddress))")

        settings.proxySettings = proxySettings
    }
}

private extension Endpoint {
    var neProxy: NEProxyServer {
        NEProxyServer(address: address.rawValue, port: Int(port))
    }
}
