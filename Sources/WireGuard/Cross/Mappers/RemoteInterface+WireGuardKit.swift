// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutWireGuard
#endif

extension WireGuard.RemoteInterface {
    init(wg: PeerConfiguration) throws {
        let wgPublicKey = wg.publicKey.base64Key
        let wgPreSharedKey = wg.preSharedKey?.base64Key

        let address: String?
        switch wg.endpoint?.host {
        case .ipv4(let nwAddress):
            address = nwAddress.debugDescription

        case .ipv6(let nwAddress):
            address = nwAddress.debugDescription

        case .name(let hostname, _):
            address = hostname

        default:
            address = nil
        }

        let endpoint: PartoutCore.Endpoint?
        if let address,
           let addressObject = Address(rawValue: address),
           let port = wg.endpoint?.port.rawValue {
            endpoint = PartoutCore.Endpoint(addressObject, port)
        } else {
            endpoint = nil
        }

        let allowedIPs = wg.allowedIPs.compactMap(Subnet.init(wg:))
        let keepAlive = wg.persistentKeepAlive

        guard let publicKey = WireGuard.Key(rawValue: wgPublicKey) else {
            fatalError("Unable to build a WireGuard.Key from a PublicKey?")
        }
        let preSharedKey = wgPreSharedKey.map {
            guard let key = WireGuard.Key(rawValue: $0) else {
                fatalError("Unable to build a WireGuard.Key from a PreSharedKey?")
            }
            return key
        }

        self.init(
            publicKey: publicKey,
            preSharedKey: preSharedKey,
            endpoint: endpoint,
            allowedIPs: allowedIPs,
            keepAlive: keepAlive
        )
    }

    func toWireGuardConfiguration() throws -> PeerConfiguration {
        guard let wgPublicKey = PublicKey(base64Key: publicKey.rawValue) else {
            throw PartoutError(.parsing)
        }
        var wg = PeerConfiguration(publicKey: wgPublicKey)
        if let preSharedKey {
            wg.preSharedKey = PreSharedKey(base64Key: preSharedKey.rawValue)
        }
        if let endpoint {
            wg.endpoint = try endpoint.toWireGuardEndpoint()
        }
        wg.allowedIPs = try allowedIPs.map {
            try $0.toWireGuardRange()
        }
        wg.persistentKeepAlive = keepAlive
        return wg
    }
}
