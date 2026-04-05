// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A codable wrapper for a profile with all known modules.
public struct TaggedProfile: ProfileType, Hashable, Codable, Sendable {
    public typealias CustomModuleHandler = @Sendable (CustomModule) throws -> Module

    public let version: Int?

    public let id: UniqueID

    public let name: String

    public let modules: [TaggedModule]

    public let activeModulesIds: Set<UniqueID>

    public let behavior: ProfileBehavior?

    public let userInfo: JSON?

    public func asProfile(customHandler: CustomModuleHandler? = nil) throws -> Profile {
        let finalModules: [Module]
        if let customHandler {
            finalModules = try modules.map {
                let inner = $0.containedModule
                if let custom = inner as? CustomModule {
                    return try customHandler(custom)
                }
                return inner
            }
        } else {
            finalModules = modules.map(\.containedModule)
        }
        return try Profile.Builder(
            version: version,
            id: id,
            name: name,
            modules: finalModules,
            activeModulesIds: activeModulesIds,
            behavior: behavior,
            userInfo: userInfo
        ).build()
    }
}

extension Profile {
    public var asTaggedProfile: TaggedProfile {
        let taggedModules = modules.compactMap(\.taggedModule)
        assert(taggedModules.count == modules.count)
        return TaggedProfile(
            version: version,
            id: id,
            name: name,
            modules: modules.compactMap(\.taggedModule),
            activeModulesIds: activeModulesIds,
            behavior: behavior,
            userInfo: userInfo
        )
    }
}
