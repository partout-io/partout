// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// An encodable wrapper for core modules.
public enum TaggedModule: Sendable {
    case dns(DNSModule)
    case httpProxy(HTTPProxyModule)
    case ip(IPModule)
    case onDemand(OnDemandModule)
}

extension Module {
    public var taggedModule: TaggedModule? {
        switch self {
        case let module as DNSModule:
            .dns(module)
        case let module as HTTPProxyModule:
            .httpProxy(module)
        case let module as IPModule:
            .ip(module)
        case let module as OnDemandModule:
            .onDemand(module)
        default:
            nil
        }
    }
}

extension TaggedModule: Encodable {
    public func encode(to encoder: Encoder) throws {
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
