//
//  OpenVPNModule.swift
//  Partout
//
//  Created by Davide De Rosa on 2/14/24.
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

extension ModuleType {
    public static let openVPN = ModuleType("OpenVPN")
}

/// A `ConnectionModule` providing an OpenVPN connection.
public struct OpenVPNModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.openVPN, OpenVPNModule.self)

    public let id: UUID

    public let configuration: OpenVPN.Configuration?

    @available(*, deprecated)
    public private(set) var providerSelection: OpenVPNLegacyProviderSelection?

    public let credentials: OpenVPN.Credentials?

    private let requiresInteractiveCredentials: Bool?

    public var isInteractive: Bool {
        if requiresCredentials {
            return true
        }
        return configuration?.staticChallenge ?? requiresInteractiveCredentials ?? false
    }

    fileprivate init(id: UUID, configuration: OpenVPN.Configuration?, credentials: OpenVPN.Credentials?, requiresInteractiveCredentials: Bool?) {
        self.id = id
        self.configuration = configuration
        self.credentials = credentials
        self.requiresInteractiveCredentials = requiresInteractiveCredentials
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            configurationBuilder: configuration?.builder(),
            credentials: credentials,
            isInteractive: requiresInteractiveCredentials ?? false
        )
    }
}

private extension OpenVPNModule {
    var requiresCredentials: Bool {
        guard configuration?.authUserPass == true else {
            return false
        }
        return credentials?.isEmpty ?? true
    }
}

extension OpenVPNModule {
    public struct Builder: ModuleBuilder, Hashable {
        public let id: UUID

        public var configurationBuilder: OpenVPN.Configuration.Builder?

        public var credentials: OpenVPN.Credentials?

        public var isInteractive: Bool

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UUID = UUID(),
            configurationBuilder: OpenVPN.Configuration.Builder? = nil,
            credentials: OpenVPN.Credentials? = nil,
            isInteractive: Bool = false
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
            self.credentials = credentials
            self.isInteractive = isInteractive
        }

        public func tryBuild() throws -> OpenVPNModule {
            guard configurationBuilder != nil else {
                throw PartoutError(.incompleteModule, self)
            }
            var builder = configurationBuilder
            builder?.staticChallenge = isInteractive
            let configuration = try builder?.tryBuild(isClient: true)
            return OpenVPNModule(
                id: id,
                configuration: configuration,
                credentials: credentials,
                requiresInteractiveCredentials: isInteractive
            )
        }
    }
}

extension OpenVPNModule: ConnectionModule {

    /// - Throws: If `impl` is not of type ``OpenVPNModule/Implementation``.
    public func newConnection(
        with impl: ModuleImplementation?,
        parameters: ConnectionParameters
    ) async throws -> Connection {
        guard let impl = impl as? Implementation else {
            throw PartoutError(.requiredImplementation)
        }
        return try await impl.connectionBlock(parameters, self)
    }
}
