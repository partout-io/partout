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

public struct WireGuardProviderSession: Hashable, Codable, Sendable {
    public struct Peer: Hashable, Codable, Sendable {
        public let clientId: String

        public let creationDate: Date

        public let addresses: [String]

        public init(clientId: String, creationDate: Date, addresses: [String]) {
            self.clientId = clientId
            self.creationDate = creationDate
            self.addresses = addresses
        }
    }

    public let privateKey: String

    public let publicKey: String

    public private(set) var peer: Peer?

    public init(keyGenerator: WireGuardKeyGenerator) throws {
        privateKey = keyGenerator.newPrivateKey()
        publicKey = try keyGenerator.publicKey(for: privateKey)
        peer = nil
    }

    public func with(peer: Peer) -> Self {
        var newSession = self
        newSession.peer = peer
        return newSession
    }
}

extension WireGuardProviderTemplate {
    public struct Options: ProviderOptions {
        public var credentials: ProviderCredentials?

        public var token: ProviderToken?

        // device id -> session
        public var sessions: [String: WireGuardProviderSession]?

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
        guard let session = options?.sessions?[deviceId] else {
            throw PartoutError(.Providers.missingProviderOption, "session")
        }
        guard let peer = session.peer else {
            throw PartoutError(.Providers.missingProviderOption, "session.peer")
        }
        configurationBuilder.interface.privateKey = session.privateKey
        configurationBuilder.interface.addresses = peer.addresses

        var builder = WireGuardModule.Builder(id: moduleId)
        builder.configurationBuilder = configurationBuilder
        return try builder.tryBuild()
    }
}

#endif
