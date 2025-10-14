// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Holds the metadata of a ``Profile``, where ``Profile/modules`` are the hash values of the profile modules.
public struct ProfileHeader: ProfileType, Identifiable, Hashable, Sendable {
    public let version: Int?

    public let id: UniqueID

    public let name: String

    public let modules: [Int]

    public let activeModulesIds: Set<UniqueID>

    public let behavior: ProfileBehavior?

    public let userInfo: Int?
}
