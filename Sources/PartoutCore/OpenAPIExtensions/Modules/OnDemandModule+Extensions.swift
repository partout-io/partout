// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OnDemandModule: Module, BuildableType {
    public static let moduleType: ModuleType = .OnDemand

    public func builder() -> Builder {
        var builder = Builder(id: id)
        builder.policy = policy
        builder.withSSIDs = withSSIDs
        builder.withOtherNetworks = withOtherNetworks
        return builder
    }
}

extension OnDemandModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var policy: Policy
        public var withSSIDs: [String: Bool]
        public var withOtherNetworks: Set<OtherNetwork>

        public static func empty() -> Self {
            self.init()
        }

        public init(id: UniqueID = UniqueID()) {
            self.id = id
            policy = .any
            withSSIDs = [:]
            withOtherNetworks = []
        }

        public func build() -> OnDemandModule {
            OnDemandModule(
                id: id,
                policy: policy,
                withOtherNetworks: withOtherNetworks,
                withSSIDs: withSSIDs
            )
        }
    }
}

extension OnDemandModule {
    public var withMobileNetwork: Bool {
        withOtherNetworks.contains(.mobile)
    }

    public var withEthernetNetwork: Bool {
        withOtherNetworks.contains(.ethernet)
    }
}

extension OnDemandModule.Builder {
    public var withMobileNetwork: Bool {
        get {
            withOtherNetworks.contains(.mobile)
        }
        set {
            if newValue {
                withOtherNetworks.insert(.mobile)
            } else {
                withOtherNetworks.remove(.mobile)
            }
        }
    }

    public var withEthernetNetwork: Bool {
        get {
            withOtherNetworks.contains(.ethernet)
        }
        set {
            if newValue {
                withOtherNetworks.insert(.ethernet)
            } else {
                withOtherNetworks.remove(.ethernet)
            }
        }
    }
}
