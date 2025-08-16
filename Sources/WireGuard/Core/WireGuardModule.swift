// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension ModuleType {
    public static let wireGuard = ModuleType("WireGuard")
}

/// A ``/PartoutCore/ConnectionModule`` providing a WireGuard connection.
public struct WireGuardModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.wireGuard, WireGuardModule.self)

    public let id: UUID

    public let configuration: WireGuard.Configuration?

    fileprivate init(id: UUID, configuration: WireGuard.Configuration?) {
        self.id = id
        self.configuration = configuration
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            configurationBuilder: configuration?.builder()
        )
    }
}

extension WireGuardModule {
    public struct Builder: ModuleBuilder, Hashable {
        public let id: UUID

        public var configurationBuilder: WireGuard.Configuration.Builder?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UUID = UUID(),
            configurationBuilder: WireGuard.Configuration.Builder? = nil
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
        }

        public func tryBuild() throws -> WireGuardModule {
            guard let configurationBuilder else {
                throw PartoutError(.incompleteModule, self)
            }
            return WireGuardModule(
                id: id,
                configuration: try configurationBuilder.tryBuild()
            )
        }
    }
}

extension WireGuardModule: ConnectionModule {

    /// - Throws: If `impl` is not of type ``WireGuardModule/Implementation``.
    public func newConnection(
        with impl: ModuleImplementation?,
        parameters: ConnectionParameters
    ) throws -> Connection {
        guard let impl = impl as? WireGuardModule.Implementation else {
            throw PartoutError(.requiredImplementation)
        }
        return try impl.connectionBlock(parameters, self)
    }
}
