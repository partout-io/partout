// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
import PartoutWireGuard
#endif

extension StandardWireGuardParser: ModuleBuilderValidator {
    public func validate(_ builder: any ModuleBuilder) throws {
        guard let builder = builder as? WireGuardModule.Builder else {
            throw PartoutError(.unknownModuleHandler)
        }
        guard let configurationBuilder = builder.configurationBuilder else {
            // assume provider configurations to be valid
            return
        }
        do {
            let quickConfig = configurationBuilder.toQuickConfig()
            _ = try TunnelConfiguration(fromWgQuickConfig: quickConfig)
        } catch {
            throw PartoutError(.parsing, error)
        }
    }
}

private extension WireGuard.Configuration.Builder {
    func toQuickConfig() -> String {
        var lines: [String] = []

        lines.append("[Interface]")
        lines.append("PrivateKey = \(interface.privateKey)")
        if !interface.addresses.isEmpty {
            lines.append("Address = \(interface.addresses.wgJoined)")
        }
        let dnsEntries = interface.dns.servers + (interface.dns.searchDomains ?? [])
        if !dnsEntries.isEmpty {
            lines.append("DNS = \(dnsEntries.wgJoined)")
        }
        if let mtu = interface.mtu {
            lines.append("MTU = \(mtu)")
        }

        peers.forEach {
            lines.append("[Peer]")
            lines.append("PublicKey = \($0.publicKey)")
            if let preSharedKey = $0.preSharedKey, !preSharedKey.isEmpty {
                lines.append("PresharedKey = \(preSharedKey)")
            }
            if !$0.allowedIPs.isEmpty {
                lines.append("AllowedIPs = \($0.allowedIPs.wgJoined)")
            }
            if let endpoint = $0.endpoint {
                lines.append("Endpoint = \(endpoint)")
            }
            if let persistentKeepAlive = $0.keepAlive {
                lines.append("PersistentKeepalive = \(persistentKeepAlive)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

private extension Collection where Element == String {
    var wgJoined: String {
        joined(separator: ",")
    }
}
