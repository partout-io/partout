// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TaggedModule {
    var containedModule: Module & Codable {
        switch self {
        case .Custom(let module): module
        case .DNS(let module): module
        case .HTTPProxy(let module): module
        case .IP(let module): module
        case .OnDemand(let module): module
        case .OpenVPN(let module): module
        case .WireGuard(let module): module
        }
    }
}

extension Module {
    var taggedModule: TaggedModule? {
        switch self {
        case let module as DNSModule:
            return .DNS(module)
        case let module as HTTPProxyModule:
            return .HTTPProxy(module)
        case let module as IPModule:
            return .IP(module)
        case let module as OnDemandModule:
            return .OnDemand(module)
        case let module as OpenVPNModule:
            return .OpenVPN(module)
        case let module as WireGuardModule:
            return .WireGuard(module)
        default:
            guard let module = self as? Module & Codable else {
                assertionFailure("Untaggable module: \(self)")
                return nil
            }
            do {
                let custom = try CustomModule(module)
                return .Custom(custom)
            } catch {
                assertionFailure("Unable to encode custom module: \(error)")
                return nil
            }
        }
    }
}
