// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// An encodable wrapper for core modules.
enum TaggedModule: Sendable {
    case dns(DNSModule)
    case httpProxy(HTTPProxyModule)
    case ip(IPModule)
    case onDemand(OnDemandModule)
}

extension Module {
    var taggedModule: TaggedModule? {
        switch self {
        case let module as DNSModule:
            return .dns(module)
        case let module as HTTPProxyModule:
            return .httpProxy(module)
        case let module as IPModule:
            return .ip(module)
        case let module as OnDemandModule:
            return .onDemand(module)
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

    // WARNING: Must match TaggedModule case
    enum Discriminator: String {
        case dns
        case httpProxy
        case ip
        case onDemand
    }

    var discriminator: Discriminator {
        switch self {
        case .dns: .dns
        case .httpProxy: .httpProxy
        case .ip: .ip
        case .onDemand: .onDemand
        }
    }

    func encodePayload(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .dns(let module):
            try container.encode(module, forKey: .value)
        case .httpProxy(let module):
            try container.encode(module, forKey: .value)
        case .ip(let module):
            try container.encode(module, forKey: .value)
        case .onDemand(let module):
            try container.encode(module, forKey: .value)
        }
    }
}
