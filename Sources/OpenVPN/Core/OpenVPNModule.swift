// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension ModuleType {
    public static let openVPN = ModuleType("OpenVPN")
}

/// A ``/PartoutCore/ConnectionModule`` providing an OpenVPN connection.
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
    ) throws -> Connection {
        guard let impl = impl as? Implementation else {
            throw PartoutError(.requiredImplementation)
        }
        return try impl.connectionBlock(parameters, self)
    }
}
