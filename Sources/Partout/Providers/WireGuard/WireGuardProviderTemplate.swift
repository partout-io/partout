//
//  WireGuardProviderTemplate.swift
//  Partout
//
//  Created by Davide De Rosa on 12/2/24.
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

#if canImport(_PartoutWireGuardCore)

import _PartoutWireGuardCore
import Foundation
import PartoutCore

// FIXME: passepartout#507, generate WireGuard configuration from template
public struct WireGuardProviderTemplate: Hashable, Codable, Sendable {
    public func builder() -> WireGuard.Configuration.Builder {
        fatalError("TODO: define WireGuard template for providers")
    }
}

extension WireGuardProviderTemplate: ProviderTemplateCompiler {

    // FIXME: passepartout#507, generate WireGuard configuration from template
    public static func compiled(
        _ ctx: PartoutLoggerContext,
        deviceId: String,
        moduleId: UUID,
        entity: ProviderEntity,
        options: WireGuardProviderStorage?
    ) throws -> WireGuardModule {
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
