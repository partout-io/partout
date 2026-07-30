// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuardModule: Module, BuildableType {
    public static let moduleType: ModuleType = .WireGuard

    public func builder() -> Builder {
        Builder(id: id, configurationBuilder: configuration?.builder())
    }
}

extension WireGuardModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var configurationBuilder: WireGuard.Configuration.Builder?

        public static func empty() -> Self {
            self.init()
        }

        public init(id: UniqueID = UniqueID(), configurationBuilder: WireGuard.Configuration.Builder? = nil) {
            self.id = id
            self.configurationBuilder = configurationBuilder
        }

        public func build() throws -> WireGuardModule {
            guard let configurationBuilder else {
                throw PartoutError(.incompleteModule, self)
            }
            return WireGuardModule(id: id, configuration: try configurationBuilder.build())
        }
    }
}
