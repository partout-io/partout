//
//  WireGuard+Providers.swift
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

import Foundation
import PartoutCore

public struct WireGuardProviderResolver: ProviderModuleResolver {
    public var moduleType: ModuleType {
        .wireGuard
    }

    public init() {
    }

    public func resolved(from providerModule: ProviderModule) throws -> Module {
        try providerModule.compiled(withTemplate: WireGuardProviderTemplate.self)
    }
}

// TODO: #339, generate WireGuard configuration from template
public struct WireGuardProviderTemplate: Hashable, Codable, Sendable {
    public func builder() -> WireGuard.Configuration.Builder {
        fatalError("FIXME: define WireGuard template for providers")
    }
}

extension WireGuardProviderTemplate {
    public struct Options: ProviderOptions {
        public var privateKey: String?

        public init() {
        }
    }
}

extension WireGuardProviderTemplate: ProviderTemplateCompiler {

    // TODO: #339, generate WireGuard configuration from template
    public static func compiled(
        with id: UUID,
        entity: ProviderEntity,
        options: Options?
    ) throws -> WireGuardModule {
        let template = try entity.preset.template(ofType: WireGuardProviderTemplate.self)
        var configurationBuilder = template.builder()
        if let privateKey = options?.privateKey {
            configurationBuilder.interface.privateKey = privateKey
        }

        var builder = WireGuardModule.Builder()
        builder.configurationBuilder = configurationBuilder
        return try builder.tryBuild()
    }
}
