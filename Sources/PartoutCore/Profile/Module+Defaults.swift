// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

private let undefinedModuleType = ModuleType("Undefined")

extension Module {
    public static var moduleType: ModuleType {
        undefinedModuleType
    }

    public var id: UniqueID {
        UniqueID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    public var fingerprint: Int {
        0
    }

    public var buildsConnection: Bool {
        self is ConnectionModule
    }

    public var isFinal: Bool {
        true
    }

    public var isInteractive: Bool {
        false
    }

    public var isMutuallyExclusive: Bool {
        true
    }

    // if isMutuallyExclusive, allow one Module of this type at most
    public func checkCompatible(with otherModule: Module, activeIds: Set<UniqueID>) throws {
        precondition(otherModule.id != id)
        if !isMutuallyExclusive {
            return
        }
        guard !(otherModule is Self) else {
            throw PartoutError(.incompatibleModules, [self, otherModule])
        }
    }
}

extension ConnectionModule {

    // allow one active ConnectionModule at most
    public func checkCompatible(with otherModule: Module, activeIds: Set<UniqueID>) throws {
        precondition(otherModule.id != id)
        if !activeIds.contains(id) || !activeIds.contains(otherModule.id) {
            return
        }
        guard !otherModule.buildsConnection else {
            throw PartoutError(.incompatibleModules, [self, otherModule])
        }
    }
}
