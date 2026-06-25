// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// WARNING: TaggedModule enum must match case of ModuleType.rawValue.

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
