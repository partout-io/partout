// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension Profile {
    func networkSettings(
        with info: TunnelRemoteInfo?,
        options: NETunnelController.Options? = nil
    ) -> NEPacketTunnelNetworkSettings {
        let ctx = PartoutLoggerContext(id)
        let tunnelRemoteAddress = info?.address?.rawValue ?? "127.0.0.1"
        var neSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        pp_log(ctx, .ne, .info, "Build NetworkExtension settings from Profile")
        pp_log(ctx, .ne, .info, "\tTunnel remote address: \(tunnelRemoteAddress.asSensitiveAddress(ctx))")

        // 1. gather active modules

        var applicableModules = modules.filter {
            isActiveModule(withId: $0.id)
        }

        // 2. inject remote modules right after the originating module

        if let info, let remoteModules = info.modules,
           let indexOfRemoteModule = applicableModules.firstIndex(where: { $0.id == info.originalModuleId }) {
            applicableModules.insert(contentsOf: remoteModules, at: indexOfRemoteModule + 1)
        }

        // 3. apply modules to NE settings

        applicableModules.forEach {
            let moduleDescription = LoggableModule(ctx, $0)
                .debugDescription(withSensitiveData: ctx.logger.logsModules)

            if let applicableModule = $0 as? Module & NESettingsApplying {
                pp_log(ctx, .ne, .info, "\t+ \(type(of: $0)): \(moduleDescription)")
                applicableModule.apply(ctx, to: &neSettings)
            } else {
                pp_log(ctx, .ne, .info, "\t- \(type(of: $0)): \(moduleDescription)")
            }
        }

        let isGatewayIPv4 = neSettings.ipv4Settings?.includedRoutes?.contains(.default()) ?? false
        let isGatewayIPv6 = neSettings.ipv6Settings?.includedRoutes?.contains(.default()) ?? false
        let isGateway = isGatewayIPv4 || isGatewayIPv6
        pp_log(ctx, .ne, .info, "\tVPN is default gateway: \(isGateway)")

        // 4. configure DNS for domain-based routing

        if let dnsSettings = neSettings.dnsSettings {

            // route DNS through VPN first unless no servers provided
            if !dnsSettings.servers.isEmpty {
                neSettings.dnsSettings?.matchDomains = [""]
            }
        }

        // 5. configure DNS for non-connection profiles

        if activeConnectionModule == nil {

            // TODO: #314/partout-core, this seems fixed in macOS 15
            // the tunnel takes several seconds to stop if
            // only DNS settings are provided. here we add some fake IP
            // settings to work around this behavior
            if neSettings.ipv4Settings == nil {
                let ipv4Settings = NEIPv4Settings(addresses: ["127.0.0.1"], subnetMasks: ["255.255.255.255"])
                neSettings.ipv4Settings = ipv4Settings
            }

            pp_log(ctx, .ne, .info, "\tRoute DNS-only settings with empty matchDomains")
        }

        // 6. optionally enable DNS fallback if default gateway without DNS settings

        if isGateway, neSettings.dnsSettings == nil {
            pp_log(ctx, .ne, .info, "\tVPN is default gateway but has no DNS settings")

            if let dnsFallbackServers = options?.dnsFallbackServers,
               !dnsFallbackServers.isEmpty {
                pp_log(ctx, .ne, .info, "\tEnable DNS fallback: \(dnsFallbackServers)")
                neSettings.dnsSettings = NEDNSSettings(servers: dnsFallbackServers)
            }
        }

        // 7. optionally route DNS through the VPN

        applicableModules.forEach {
            guard let dnsModule = $0 as? DNSModule else {
                return
            }
            guard let routesThroughVPN = dnsModule.routesThroughVPN else {
                return
            }
            if routesThroughVPN {
                pp_log(ctx, .ne, .info, "\tRoute DNS inside the VPN")
            } else {
                pp_log(ctx, .ne, .info, "\tRoute DNS outside the VPN")
            }
            dnsModule.servers.forEach {
                switch $0 {
                case .ip(let addr, let family):
                    switch family {
                    case .v4:
                        guard let settings = neSettings.ipv4Settings else {
                            return
                        }
                        let route = NEIPv4Route(destinationAddress: addr, subnetMask: "255.255.255.255")
                        if routesThroughVPN {
                            pp_log(ctx, .ne, .info, "\t\tInclude \(addr.asSensitiveAddress(ctx))")
                            settings.includedRoutes = (settings.includedRoutes ?? []) + [route]
                        } else {
                            pp_log(ctx, .ne, .info, "\t\tExclude \(addr.asSensitiveAddress(ctx))")
                            settings.excludedRoutes = (settings.excludedRoutes ?? []) + [route]
                        }
                        neSettings.ipv4Settings = settings
                    case .v6:
                        guard let settings = neSettings.ipv6Settings else {
                            return
                        }
                        let route = NEIPv6Route(destinationAddress: addr, networkPrefixLength: 128)
                        if routesThroughVPN {
                            pp_log(ctx, .ne, .info, "\t\tInclude \(addr.asSensitiveAddress(ctx))")
                            settings.includedRoutes = (settings.includedRoutes ?? []) + [route]
                        } else {
                            pp_log(ctx, .ne, .info, "\t\tExclude \(addr.asSensitiveAddress(ctx))")
                            settings.excludedRoutes = (settings.excludedRoutes ?? []) + [route]
                        }
                        neSettings.ipv6Settings = settings
                    }
                case .hostname:
                    assertionFailure("DNS servers must be IP addresses")
                }
            }
        }

        return neSettings
    }
}
