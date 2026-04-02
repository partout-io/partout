// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension ModuleType {
    public static let DNS = DNSModule.moduleType
    public static let HTTPProxy = HTTPProxyModule.moduleType
    public static let IP = IPModule.moduleType
    public static let OnDemand = OnDemandModule.moduleType
    public static let OpenVPN = OpenVPNModule.moduleType
    public static let WireGuard = WireGuardModule.moduleType
}

extension ModuleType {
    public var builderType: (any ModuleBuilder.Type)? {
        switch self {
        case .DNS:
            return DNSModule.Builder.self
        case .HTTPProxy:
            return HTTPProxyModule.Builder.self
        case .IP:
            return IPModule.Builder.self
        case .OnDemand:
            return OnDemandModule.Builder.self
        case .OpenVPN:
            return OpenVPNModule.Builder.self
        case .WireGuard:
            return WireGuardModule.Builder.self
        default:
            assertionFailure("ModuleType '\(rawValue)' has no ModuleBuilder associated")
            return nil
        }
    }
}
