// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ModuleType {
    public static let filter = ModuleType("Filter")
}

/// A module that filters the effect of other modules.
public struct FilterModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.filter, FilterModule.self)

    public enum IgnoreBit: Hashable, Codable, Sendable {
        case ipv4

        case ipv6

        case dns

        case proxy

        case mtu
    }

    public let id: UniqueID

    public let disabledMask: Set<IgnoreBit>

    fileprivate init(id: UniqueID, disabledMask: Set<IgnoreBit>) {
        self.id = id
        self.disabledMask = disabledMask
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            disabledMask: disabledMask
        )
    }
}

extension FilterModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID

        public var disabledMask: Set<IgnoreBit>

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            disabledMask: Set<IgnoreBit> = []
        ) {
            self.id = id
            self.disabledMask = disabledMask
        }

        public func build() -> FilterModule {
            FilterModule(
                id: id,
                disabledMask: disabledMask
            )
        }
    }
}
