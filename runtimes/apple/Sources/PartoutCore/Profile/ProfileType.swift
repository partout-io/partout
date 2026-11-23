// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Generic representation of a profile.
public protocol ProfileType: UniquelyIdentifiable {
    associatedtype GenericModuleType

    associatedtype UserInfoType: Hashable

    /// The version.
    var version: Int? { get }

    /// The unique identifier.
    var id: UniqueID { get }

    /// The name.
    var name: String { get }

    /// The generic modules.
    var modules: [GenericModuleType] { get }

    /// The identifiers of the active modules.
    var activeModulesIds: Set<UniqueID> { get }

    /// Optional settings about overall profile behavior.
    var behavior: ProfileBehavior? { get }

    /// Optional user info.
    var userInfo: UserInfoType? { get }
}

/// Mutable version of ``ProfileType``.
public protocol MutableProfileType: ProfileType {
    var name: String { get set }

    var modules: [GenericModuleType] { get set }

    var activeModulesIds: Set<UniqueID> { get set }

    var userInfo: UserInfoType? { get set }
}
