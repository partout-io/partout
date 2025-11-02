// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ModuleType {
    public static let ip = ModuleType("IP")
}

/// IP and routes.
public struct IPModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.ip, IPModule.self)

    public let id: UniqueID

    public let ipv4: IPSettings?

    public let ipv6: IPSettings?

    public let mtu: Int?

    fileprivate init(id: UniqueID, ipv4: IPSettings?, ipv6: IPSettings?, mtu: Int?) {
        self.id = id
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.mtu = mtu
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            ipv4: ipv4,
            ipv6: ipv6,
            mtu: mtu
        )
    }
}

extension IPModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID

        public var ipv4: IPSettings?

        public var ipv6: IPSettings?

        public var mtu: Int?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            ipv4: IPSettings? = nil,
            ipv6: IPSettings? = nil,
            mtu: Int? = nil
        ) {
            self.id = id
            self.ipv4 = ipv4
            self.ipv6 = ipv6
            self.mtu = mtu
        }

        public func build() -> IPModule {
            IPModule(
                id: id,
                ipv4: ipv4?.nilIfEmpty,
                ipv6: ipv6?.nilIfEmpty,
                mtu: mtu
            )
        }
    }
}
