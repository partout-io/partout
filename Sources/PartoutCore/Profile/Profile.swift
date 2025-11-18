// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Coordinates a set of ``Module`` to provide extensible networking capabilities.
public struct Profile: ProfileType, BuildableType, Identifiable, Sendable {
    public let version: Int?

    public let id: UniqueID

    public let name: String

    public let modules: [Module]

    public let activeModulesIds: Set<UniqueID>

    public let behavior: ProfileBehavior?

    public let userInfo: JSON?

    private init(
        version: Int?,
        id: UniqueID,
        name: String,
        modules: [Module],
        activeModulesIds: Set<UniqueID>,
        behavior: ProfileBehavior?,
        userInfo: JSON?
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.modules = modules
        self.activeModulesIds = activeModulesIds
        self.behavior = behavior
        self.userInfo = userInfo
    }

    public func builder() -> Builder {
        builder(withNewId: false, forUpgrade: false)
    }

    public func builder(withNewId: Bool, forUpgrade: Bool = false) -> Builder {
        Builder(
            version: forUpgrade ? Builder.currentVersion : version,
            id: withNewId ? UniqueID() : id,
            name: name,
            modules: modules,
            activeModulesIds: activeModulesIds,
            behavior: behavior,
            userInfo: userInfo
        )
    }
}

extension Profile {
    public struct Builder: MutableProfileType, BuilderType {
        public static let currentVersion = 2

        public let version: Int?

        public let id: UniqueID

        public var name: String

        public var modules: [Module] {
            didSet {
                activeModulesIds.formIntersection(modules.map(\.id))
            }
        }

        public var activeModulesIds: Set<UniqueID>

        public var behavior: ProfileBehavior?

        public var userInfo: JSON?

        public var check: ((Self) throws -> Void)?

        init(
            version: Int?,
            id: UniqueID = UniqueID(),
            name: String = "",
            modules: [Module] = [],
            activeModulesIds: Set<UniqueID> = [],
            behavior: ProfileBehavior? = nil,
            userInfo: JSON? = nil
        ) {
            self.version = version
            self.id = id
            self.name = name
            self.modules = modules
            self.activeModulesIds = activeModulesIds
            self.behavior = behavior
            self.userInfo = userInfo
        }

        public init(
            id: UniqueID = UniqueID(),
            name: String = "",
            modules: [Module] = [],
            activeModulesIds: Set<UniqueID> = [],
            behavior: ProfileBehavior? = nil,
            userInfo: JSON? = nil
        ) {
            self.init(
                version: Self.currentVersion,
                id: id,
                name: name,
                modules: modules,
                activeModulesIds: activeModulesIds,
                behavior: behavior,
                userInfo: userInfo
            )
        }

        public init(
            id: UniqueID = UniqueID(),
            name: String = "",
            modules: [Module] = [],
            activatingModules: Bool = true
        ) {
            self.init(
                version: Self.currentVersion,
                id: id,
                name: name,
                modules: modules,
                activeModulesIds: activatingModules ? Set(modules.map(\.id)) : []
            )
        }

        public mutating func saveModule(_ module: Module) {
            if let index = modules.firstIndex(where: { $0.id == module.id }) {
                modules[index] = module
            } else {
                modules.append(module)
            }
        }

        public func build() throws -> Profile {
            try checkCompatibility()

            let allIds = Set(modules.map(\.id))
            let knownActiveModulesIds = activeModulesIds.intersection(allIds)

            return Profile(
                version: version,
                id: id,
                name: name,
                modules: modules,
                activeModulesIds: knownActiveModulesIds,
                behavior: behavior,
                userInfo: userInfo
            )
        }
    }
}

extension Profile.Builder {
    func checkCompatibility() throws {
        try modules.enumerated().forEach { li, lhs in
            try modules.enumerated().forEach { ri, rhs in

                // skip duplicated pairs
                guard ri > li else {
                    return
                }
                guard lhs.id != rhs.id else {
                    return
                }

                do {
                    try lhs.checkCompatible(with: rhs, activeIds: activeModulesIds)
                    try rhs.checkCompatible(with: lhs, activeIds: activeModulesIds)
                } catch {
                    pp_log_id(id, .core, .error, "Modules are incompatible: \(lhs), \(rhs)")
                    throw error
                }
            }
        }

        // check any extra requirements
        try check?(self)
    }
}

// MARK: - Hashable

extension Profile: Hashable {
}

extension Profile.Builder: Hashable {
}

// MARK: - Shortcuts

extension Profile {
    public func duplicate(withSuffix suffix: String) throws -> Profile {
        var copy = builder(withNewId: true)
        copy.name += suffix
        return try copy.build()
    }

    public func withoutUserInfo() throws -> Self {
        var copy = builder()
        copy.userInfo = nil
        return try copy.build()
    }
}

// MARK: - Logging

extension Profile {
    public func log(_ category: LoggerCategory, _ level: DebugLog.Level, withPreamble preamble: String) {
        let ctx = PartoutLoggerContext(id)
        pp_log(ctx, category, level, "\(preamble)")
        pp_log(ctx, category, level, "\tID: \(id)")
        pp_log(ctx, category, level, "\tName: \(name)")
        if let behavior {
            pp_log(ctx, category, level, "\tBehavior: \(behavior)")
        }
        pp_log(ctx, category, level, "\tModules:")
        modules.forEach {
            let moduleDescription = LoggableModule(ctx, $0)
                .debugDescription(withSensitiveData: ctx.logger.logsModules)

            pp_log(ctx, category, level, "\t\t\(isActiveModule(withId: $0.id) ? "+" : "-") \(type(of: $0)): \(moduleDescription)")
        }
    }
}
