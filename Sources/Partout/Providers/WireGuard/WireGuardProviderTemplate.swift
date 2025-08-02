// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutWireGuard)

import Foundation
import PartoutCore
import PartoutWireGuard

public struct WireGuardProviderTemplate: Hashable, Codable, Sendable {
    public struct UserInfo: Sendable {
        public let deviceId: String

        public init(deviceId: String) {
            self.deviceId = deviceId
        }
    }

    public let ports: [UInt16]

    public init(ports: [UInt16]) {
        self.ports = ports
    }
}

extension WireGuardProviderTemplate: ProviderTemplateCompiler {
    public func compiled(
        _ ctx: PartoutLoggerContext,
        moduleId: UUID,
        entity: ProviderEntity,
        options: WireGuardProviderStorage?,
        userInfo: UserInfo?
    ) throws -> WireGuardModule {
        guard let deviceId = userInfo?.deviceId else {
            throw PartoutError(.Providers.missingOption, "userInfo.deviceId")
        }
        guard let serverPublicKey = entity.server.userInfo?["wgPublicKey"] as? String else {
            throw PartoutError(.Providers.missingOption, "entity.server.wgPublicKey")
        }
        let serverPreSharedKey = entity.server.userInfo?["wgPreSharedKey"] as? String
        guard let session = options?.sessions?[deviceId] else {
            throw PartoutError(.Providers.missingOption, "session")
        }
        guard let peer = session.peer else {
            throw PartoutError(.Providers.missingOption, "session.peer")
        }
        let template = try entity.preset.template(ofType: WireGuardProviderTemplate.self)
        guard !template.ports.isEmpty else {
            throw PartoutError(.Providers.missingOption, "template.ports")
        }
        let addresses = entity.server.allAddresses
        guard !addresses.isEmpty else {
            throw PartoutError(.Providers.missingOption, "entity.server.allAddresses")
        }

        // local interface from session
        var configurationBuilder = WireGuard.Configuration.Builder(privateKey: session.privateKey)
        configurationBuilder.interface.addresses = peer.addresses

        // remote interfaces from infrastructure
        configurationBuilder.peers = addresses.reduce(into: []) { list, addr in
            template.ports.forEach { port in
                var peer = WireGuard.RemoteInterface.Builder(publicKey: serverPublicKey)
                peer.preSharedKey = serverPreSharedKey
                peer.endpoint = "\(addr):\(port)"
                peer.allowedIPs = ["0.0.0.0/0", "::/0"]
                list.append(peer)
            }
        }

        var builder = WireGuardModule.Builder(id: moduleId)
        builder.configurationBuilder = configurationBuilder
        return try builder.tryBuild()
    }
}

#endif
