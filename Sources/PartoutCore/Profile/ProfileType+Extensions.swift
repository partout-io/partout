// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// MARK: - Header

extension ProfileType where GenericModuleType == Module {

    // compare modules "optimistically" by fingerprint
    public func header() -> ProfileHeader {
        ProfileHeader(
            version: version,
            id: id,
            name: name,
            modules: modules.map(\.fingerprint),
            activeModulesIds: activeModulesIds,
            behavior: behavior,
            userInfo: userInfo?.hashValue
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.header() == rhs.header()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(header())
    }
}

// MARK: - CRUD

extension ProfileType {
    public func isActiveModule(withId id: UniqueID) -> Bool {
        activeModulesIds.contains(id)
    }

    public var disconnectsOnSleep: Bool {
        behavior?.disconnectsOnSleep ?? false
    }

    public var includesAllNetworks: Bool {
        behavior?.includesAllNetworks ?? false
    }
}

extension ProfileType where GenericModuleType == Module {
    public func module(withId id: UniqueID) -> Module? {
        modules.first {
            $0.id == id
        }
    }

    public var activeModules: [GenericModuleType] {
        modules.filter {
            isActiveModule(withId: $0.id)
        }
    }

    public var activeConnectionModule: ConnectionModule? {
        activeModules.first(ofType: ConnectionModule.self)
    }

    public func firstModule<T>(ofType type: T.Type, ifActive: Bool = false) -> T? where T: Module {
        guard let found = modules.first(ofType: type) else {
            return nil
        }
        if ifActive {
            guard isActiveModule(withId: found.id) else {
                return nil
            }
        }
        return found
    }

    public func firstBuildingConnection(ifActive: Bool = false) -> Module? {
        guard let found = modules.first(where: \.buildsConnection) else {
            return nil
        }
        if ifActive {
            guard isActiveModule(withId: found.id) else {
                return nil
            }
        }
        return found
    }

    public var isFinal: Bool {
        modules.allSatisfy {
            $0.isFinal || !isActiveModule(withId: $0.id)
        }
    }
}

extension MutableProfileType where GenericModuleType == Module {
    public mutating func activateAllModules() {
        activeModulesIds = Set(modules.map(\.id))
    }

    public mutating func activateModule(withId moduleId: UniqueID) {
        activeModulesIds.insert(moduleId)
    }

    public mutating func toggleModule(withId moduleId: UniqueID) {
        precondition(modules.contains(where: { $0.id == moduleId }))
        if !isActiveModule(withId: moduleId) {
            activeModulesIds.insert(moduleId)
        } else {
            activeModulesIds.remove(moduleId)
        }
    }

    public mutating func toggleExclusiveModule(withId moduleId: UniqueID, excluding: (Module) -> Bool) {
        precondition(modules.contains(where: { $0.id == moduleId }))
        if !isActiveModule(withId: moduleId) {
            modules
                .filter {
                    excluding($0)
                }
                .forEach {
                    activeModulesIds.remove($0.id)
                }

            activeModulesIds.insert(moduleId)
        } else {
            activeModulesIds.remove(moduleId)
        }
    }
}

// MARK: - Interactive

extension ProfileType where GenericModuleType == Module {
    public var isInteractive: Bool {
        interactiveModules?.isEmpty == false
    }

    public var interactiveModules: [Module]? {
        modules.filter {
            isActiveModule(withId: $0.id) && $0.isInteractive
        }
    }
}
