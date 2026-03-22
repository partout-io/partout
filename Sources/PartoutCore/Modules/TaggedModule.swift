// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// WARNING: These must all match 100% in case
//
// - ModuleType
// - TaggedModule
// - TaggedModule.Discriminator

/// An encodable wrapper for core modules.
enum TaggedModule: Sendable {
    case DNS(DNSModule)
    case HTTPProxy(HTTPProxyModule)
    case IP(IPModule)
    case OnDemand(OnDemandModule)
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
        default:
            assertionFailure("Unhandled Core module: \(self)")
            return nil
        }
    }
}

extension TaggedModule: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(discriminator.rawValue, forKey: .type)
        try encodePayload(to: &container)
    }
}

private extension TaggedModule {
    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    enum Discriminator: String {
        case DNS
        case HTTPProxy
        case IP
        case OnDemand
    }

    var discriminator: Discriminator {
        switch self {
        case .DNS: .DNS
        case .HTTPProxy: .HTTPProxy
        case .IP: .IP
        case .OnDemand: .OnDemand
        }
    }

    var containedModule: Module & Encodable {
        switch self {
        case .DNS(let module): module
        case .HTTPProxy(let module): module
        case .IP(let module): module
        case .OnDemand(let module): module
        }
    }

    func encodePayload(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        let module = containedModule
        assert(
            module.moduleType.rawValue == discriminator.rawValue,
            "Module has type '\(module.moduleType)' but discriminator '\(discriminator.rawValue)'"
        )
        try container.encode(module, forKey: .value)
    }

    func assertDiscriminator(_ module: Module) {
        assert(module.moduleType.rawValue == discriminator.rawValue)
    }
}
