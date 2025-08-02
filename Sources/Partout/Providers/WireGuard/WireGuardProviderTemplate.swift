// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(PartoutWireGuard)

import Foundation
import PartoutCore
import PartoutWireGuard

// FIXME: passepartout#507, generate WireGuard configuration from template
public struct WireGuardProviderTemplate: Hashable, Codable, Sendable {
    public func builder() -> WireGuard.Configuration.Builder {
        fatalError("TODO: define WireGuard template for providers")
    }
}

extension WireGuardProviderTemplate: ProviderTemplateCompiler {
    public static func compiled(
        _ ctx: PartoutLoggerContext,
        moduleId: UUID,
        entity: ProviderEntity,
        options: WireGuardProviderStorage?,
        userInfo: [String: Any]?
    ) throws -> WireGuardModule {
        guard let deviceId = userInfo?[WireGuardProviderResolver.UserInfo.deviceId.rawValue] as? String else {
            throw PartoutError(.Providers.missingOption, "deviceId")
        }
        let template = try entity.preset.template(ofType: WireGuardProviderTemplate.self)
        var configurationBuilder = template.builder()
        guard let session = options?.sessions?[deviceId] else {
            throw PartoutError(.Providers.missingOption, "session")
        }
        guard let peer = session.peer else {
            throw PartoutError(.Providers.missingOption, "session.peer")
        }
        configurationBuilder.interface.privateKey = session.privateKey
        configurationBuilder.interface.addresses = peer.addresses

        var builder = WireGuardModule.Builder(id: moduleId)
        builder.configurationBuilder = configurationBuilder
        return try builder.tryBuild()
    }
}

#endif
