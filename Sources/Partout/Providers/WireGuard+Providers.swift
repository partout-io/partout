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

#if canImport(_PartoutWireGuardCore)

import _PartoutWireGuardCore
import Foundation
import PartoutCore

public struct WireGuardProviderResolver: ProviderModuleResolver {
    private let ctx: PartoutLoggerContext

    public var moduleType: ModuleType {
        .wireGuard
    }

    public init(_ ctx: PartoutLoggerContext) {
        self.ctx = ctx
    }

    public func resolved(from providerModule: ProviderModule, deviceId: String) throws -> Module {
        try providerModule.compiled(
            ctx,
            withTemplate: WireGuardProviderTemplate.self,
            onDevice: deviceId
        )
    }
}

// TODO: #7, generate WireGuard configuration from template
public struct WireGuardProviderTemplate: Hashable, Codable, Sendable {
    public func builder() -> WireGuard.Configuration.Builder {
        fatalError("TODO: define WireGuard template for providers")
    }
}

public struct WireGuardProviderAuth: Hashable, Codable, Sendable {
    public struct Peer: Identifiable, Hashable, Codable, Sendable {
        public let id: String

        public let privateKey: String

        public let addresses: [String]

        public init(id: String, privateKey: String, addresses: [String]) {
            self.id = id
            self.privateKey = privateKey
            self.addresses = addresses
        }
    }

    public let token: ProviderToken?

    public let peer: Peer?

    public init(token: ProviderToken?, peer: Peer?) {
        self.token = token
        self.peer = peer
    }
}

extension WireGuardProviderTemplate {
    public struct Options: ProviderOptions {

        // device id -> auth
        public var deviceAuth: [String: WireGuardProviderAuth]?

        public init() {
        }
    }
}

extension WireGuardProviderTemplate: ProviderTemplateCompiler {

    // TODO: #7, generate WireGuard configuration from template
    public static func compiled(
        _ ctx: PartoutLoggerContext,
        deviceId: String,
        moduleId: UUID,
        entity: ProviderEntity,
        options: Options?
    ) throws -> WireGuardModule {
        let template = try entity.preset.template(ofType: WireGuardProviderTemplate.self)
        var configurationBuilder = template.builder()
        guard let peer = options?.deviceAuth?[deviceId]?.peer else {
            throw PartoutError(.Providers.missingProviderOption, "auth.peer")
        }
        configurationBuilder.interface.privateKey = peer.privateKey
        configurationBuilder.interface.addresses = peer.addresses

        var builder = WireGuardModule.Builder(id: moduleId)
        builder.configurationBuilder = configurationBuilder
        return try builder.tryBuild()
    }
}

#endif
