// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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

extension TaggedModule: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        let type = ModuleType(rawType)
        let value = try container.superDecoder(forKey: .value)
        switch type {
        case .Custom:
            self = .Custom(try CustomModule(from: value))
        case .DNS:
            self = .DNS(try DNSModule(from: value))
        case .HTTPProxy:
            self = .HTTPProxy(try HTTPProxyModule(from: value))
        case .IP:
            self = .IP(try IPModule(from: value))
        case .OnDemand:
            self = .OnDemand(try OnDemandModule(from: value))
        case .OpenVPN:
            self = .OpenVPN(try OpenVPNModule(from: value))
        case .WireGuard:
            self = .WireGuard(try WireGuardModule(from: value))
        default:
            throw PartoutError(.decoding, "Unknown discriminator '\(rawType)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(discriminator.rawValue, forKey: .type)
        let module = containedModule
        assert(
            module.moduleType.rawValue == discriminator.rawValue,
            "Module has type '\(module.moduleType)' but discriminator '\(discriminator.rawValue)'"
        )
        try container.encode(module, forKey: .value)
    }
}

private extension TaggedModule {
    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    var discriminator: ModuleType {
        switch self {
        case .Custom: .Custom
        case .DNS: .DNS
        case .HTTPProxy: .HTTPProxy
        case .IP: .IP
        case .OnDemand: .OnDemand
        case .OpenVPN: .OpenVPN
        case .WireGuard: .WireGuard
        }
    }
}
