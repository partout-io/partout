// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension WireGuard.LocalInterface {
    init(wg: InterfaceConfiguration) throws {
        let wgPrivateKey = wg.privateKey.base64Key
        let addresses = wg.addresses.compactMap(Subnet.init(wg:))

        var dnsBuilder = DNSModule.Builder()
        dnsBuilder.servers = wg.dns.map(\.stringRepresentation)
        dnsBuilder.searchDomains = wg.dnsSearch
        let dns = try dnsBuilder.build()

        let mtu = wg.mtu

        guard let privateKey = WireGuard.Key(rawValue: wgPrivateKey) else {
            fatalError("Unable to build a WireGuard.Key from a PrivateKey?")
        }

        self.init(
            privateKey: privateKey,
            addresses: addresses,
            dns: dns,
            mtu: mtu
        )
    }

    func toWireGuardConfiguration() throws -> InterfaceConfiguration {
        guard let wgPrivateKey = PrivateKey(base64Key: privateKey.rawValue) else {
            throw PartoutError(.parsing)
        }
        var wg = InterfaceConfiguration(privateKey: wgPrivateKey)
        wg.addresses = try addresses.map {
            try $0.toWireGuardRange()
        }
        if let dns {
            wg.dns = try dns.servers.map {
                try $0.rawValue.toWireGuardDNS()
            }
            wg.dnsSearch = dns.searchDomains?.map(\.rawValue) ?? []
        }
        wg.mtu = mtu
        return wg
    }
}

extension String {
    func toWireGuardDNS() throws -> DNSServer {
        guard let wg = DNSServer(from: self) else {
            throw PartoutError(.parsing)
        }
        return wg
    }
}
