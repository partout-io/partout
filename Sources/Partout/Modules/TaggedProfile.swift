// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A codable wrapper for a profile with all known modules.
public struct TaggedProfile: ProfileType, Hashable, Codable, Sendable {
    public let version: Int?

    public let id: UniqueID

    public let name: String

    public let modules: [TaggedModule]

    public let activeModulesIds: Set<UniqueID>

    public let behavior: ProfileBehavior?

    public let userInfo: JSON?

    public func asProfile() throws -> Profile {
        try Profile.Builder(
            version: version,
            id: id,
            name: name,
            modules: modules.compactMap(\.containedModule),
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
