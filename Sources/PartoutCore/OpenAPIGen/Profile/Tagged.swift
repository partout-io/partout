// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// Generated from scripts/openapi.yaml. Do not edit by hand.


// WARNING: TaggedModule enum must match case of ModuleType.rawValue

/// A codable wrapper for all known modules.
public enum TaggedModule: Hashable, Sendable {
    case Custom(CustomModule)
    case DNS(DNSModule)
    case HTTPProxy(HTTPProxyModule)
    case IP(IPModule)
    case OnDemand(OnDemandModule)
    case OpenVPN(OpenVPNModule)
    case WireGuard(WireGuardModule)
}

/// A codable wrapper for a profile with all known modules.
public struct TaggedProfile: Hashable, Codable, Sendable {
    public let version: Int?
    public let id: UniqueID
    public let name: String
    public let modules: [TaggedModule]
    public let activeModulesIds: Set<UniqueID>
    public let behavior: ProfileBehavior?
    public let userInfo: JSON?

    public init(
        version: Int?,
        id: UniqueID,
        name: String,
        modules: [TaggedModule],
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
}
