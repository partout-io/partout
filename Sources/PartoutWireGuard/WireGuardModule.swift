// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension ModuleType {
    public static let wireGuard = ModuleType("WireGuard")
}

/// A connection module providing a WireGuard connection.
public struct WireGuardModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.wireGuard, WireGuardModule.self)

    public let id: UniqueID

    public let configuration: WireGuard.Configuration?

    fileprivate init(id: UniqueID, configuration: WireGuard.Configuration?) {
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
        public let id: UniqueID

        public var configurationBuilder: WireGuard.Configuration.Builder?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            configurationBuilder: WireGuard.Configuration.Builder? = nil
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
        }

        public func build() throws -> WireGuardModule {
            guard let configurationBuilder else {
                throw PartoutError(.incompleteModule, self)
            }
            return WireGuardModule(
                id: id,
                configuration: try configurationBuilder.build()
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
