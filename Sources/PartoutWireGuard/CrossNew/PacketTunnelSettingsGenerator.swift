// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//  SPDX-License-Identifier: MIT
//  Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import _PartoutWireGuard_C
import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutWireGuard
#endif

final class PacketTunnelSettingsGenerator: Sendable {
    private let tunnelConfiguration: WireGuard.Configuration

    init(tunnelConfiguration: WireGuard.Configuration) {
        self.tunnelConfiguration = tunnelConfiguration
    }

    func uapiConfiguration(logHandler: @escaping WireGuardAdapter.LogHandler) async -> String {
        var wgSettings = ""
        wgSettings.append("private_key=\(tunnelConfiguration.interface.privateKey.rawValue.hexStringFromBase64)\n")
        // TODO: #93, listenPort not implemented
//        if let listenPort = tunnelConfiguration.interface.listenPort {
//            wgSettings.append("listen_port=\(listenPort)\n")
//        }
        if !tunnelConfiguration.peers.isEmpty {
            wgSettings.append("replace_peers=true\n")
        }

        // address: String -> resolvedEndpoints: [Endpoint]
        let resolutionMap = await tunnelConfiguration.resolvePeers {
            logHandler($0, $1)
        }

        for peer in tunnelConfiguration.peers {
            wgSettings.append("public_key=\(peer.publicKey.rawValue.hexStringFromBase64)\n")
            if let preSharedKey = peer.preSharedKey?.rawValue {
                wgSettings.append("preshared_key=\(preSharedKey.hexStringFromBase64)\n")
            }
            guard let endpoint = peer.endpoint else { continue }
            for resolvedEndpoint in resolutionMap[endpoint.address] ?? [] {
                if case .hostname = resolvedEndpoint.address { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.wgRepresentation)\n")
            }
            let persistentKeepAlive = peer.keepAlive ?? 0
            wgSettings.append("persistent_keepalive_interval=\(persistentKeepAlive)\n")
            if !peer.allowedIPs.isEmpty {
                wgSettings.append("replace_allowed_ips=true\n")
                peer.allowedIPs.forEach { wgSettings.append("allowed_ip=\($0.rawValue)\n") }
            }
        }
        return wgSettings
    }

    func generateNetworkSettings(moduleId: UUID, descriptors: [Int32]) -> TunnelRemoteInfo {
        /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
         * a tunnel to have no endpoint, or for there to be many endpoints, in
         * which case, displaying a single one in settings doesn't really
         * make sense. So, we fill it in with this placeholder, which is not
         * a valid IP address that will actually route over the Internet.
         */
        let remoteAddress = Address(rawValue: "127.0.0.1")
        assert(remoteAddress != nil)

        let (ipv4Addresses, ipv6Addresses) = addresses()
        let (ipv4IncludedRoutes, ipv6IncludedRoutes) = includedRoutes()
        let ipv4 = IPSettings(subnets: ipv4Addresses)
            .including(routes: ipv4IncludedRoutes)
        let ipv6 = IPSettings(subnets: ipv6Addresses)
            .including(routes: ipv6IncludedRoutes)
        let mtu = tunnelConfiguration.interface.mtu ?? 0
        let ipModule = IPModule.Builder(ipv4: ipv4, ipv6: ipv6, mtu: Int(mtu)).tryBuild()

        var modules: [Module] = []
        modules.append(ipModule)
        if let dns = tunnelConfiguration.interface.dns {
            modules.append(dns)
        }

        return TunnelRemoteInfo(
            originalModuleId: moduleId,
            address: remoteAddress,
            modules: modules,
            fileDescriptors: descriptors.map(UInt64.init)
        )
    }

    private func addresses() -> ([Subnet], [Subnet]) {
        var ipv4: [Subnet] = []
        var ipv6: [Subnet] = []
        for subnet in tunnelConfiguration.interface.addresses {
            switch subnet.address {
            case .ip(_, let family):
                switch family {
                case .v4: ipv4.append(subnet)
                case .v6: ipv6.append(subnet)
                }
            default:
                break
            }
        }
        return (ipv4, ipv6)
    }

    private func includedRoutes() -> ([Route], [Route]) {
        var ipv4IncludedRoutes: [Route] = []
        var ipv6IncludedRoutes: [Route] = []
        for subnet in tunnelConfiguration.interface.addresses {
            switch subnet.address {
            case .ip(_, let family):
                let route = Route(subnet, subnet.address)
                switch family {
                case .v4: ipv4IncludedRoutes.append(route)
                case .v6: ipv6IncludedRoutes.append(route)
                }
            default:
                break
            }
        }
        for peer in tunnelConfiguration.peers {
            for subnet in peer.allowedIPs {
                switch subnet.address {
                case .ip(_, let family):
                    let route = Route(subnet, nil)
                    switch family {
                    case .v4: ipv4IncludedRoutes.append(route)
                    case .v6: ipv6IncludedRoutes.append(route)
                    }
                default:
                    break
                }
            }
        }
        return (ipv4IncludedRoutes, ipv6IncludedRoutes)
    }
}
