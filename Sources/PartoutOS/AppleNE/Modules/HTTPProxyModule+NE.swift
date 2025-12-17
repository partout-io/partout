// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension HTTPProxyModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        let proxySettings = NEProxySettings()

        proxy.map {
            proxySettings.httpEnabled = true
            proxySettings.httpServer = $0.neProxy
            pp_log(ctx, .os, .info, "\t\tHTTP server: \($0.asSensitiveAddress(ctx))")
        }
        secureProxy.map {
            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = $0.neProxy
            pp_log(ctx, .os, .info, "\t\tHTTPS server: \($0.asSensitiveAddress(ctx))")
        }
        pacURL.map {
            proxySettings.autoProxyConfigurationEnabled = true
            proxySettings.proxyAutoConfigurationURL = $0
            pp_log(ctx, .os, .info, "\t\tPAC URL: \($0.absoluteString.asSensitiveAddress(ctx))")
        }
        proxySettings.exceptionList = bypassDomains.map(\.rawValue)
        pp_log(ctx, .os, .info, "\t\tBypass domains: \(bypassDomains.map { $0.asSensitiveAddress(ctx) })")

        settings.proxySettings = proxySettings
    }
}

private extension Endpoint {
    var neProxy: NEProxyServer {
        NEProxyServer(address: address.rawValue, port: Int(port))
    }
}
