// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ModuleType {
    public static let onDemand = ModuleType("OnDemand")
}

/// On-demand settings.
public struct OnDemandModule: Module, BuildableType, Hashable, Codable {
    public enum Policy: String, Codable, Sendable {
        case any

        case including

        case excluding // "trusted networks"
    }

    public enum OtherNetwork: String, Codable, Sendable {
        case mobile

        case ethernet
    }

    public static let moduleHandler = ModuleHandler(.onDemand, OnDemandModule.self)

    public let id: UniqueID

    public let policy: Policy

    public let withSSIDs: [String: Bool]

    public let withOtherNetworks: Set<OtherNetwork>

    fileprivate init(
        id: UniqueID,
        policy: Policy,
        withSSIDs: [String: Bool],
        withOtherNetworks: Set<OtherNetwork>
    ) {
        self.id = id
        self.policy = policy
        self.withSSIDs = withSSIDs
        self.withOtherNetworks = withOtherNetworks
    }

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
                withSSIDs: withSSIDs,
                withOtherNetworks: withOtherNetworks
            )
        }
    }
}

// MARK: - Extensions

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
