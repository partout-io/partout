// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Network

/// A hostname or IP address.
@frozen
public enum Address: Hashable, Codable, Sendable {
    case ip(String, _ family: Family)
    case hostname(String)

    @frozen
    public enum Family: String, Sendable {
        case v4
        case v6
    }
}

extension Address: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .ip(let string, _):
            return string
        case .hostname(let string):
            return string
        }
    }

    public var isIPAddress: Bool {
        guard case .ip = self else {
            return false
        }
        return true
    }

    public var family: Family? {
        switch self {
        case .ip(_, let family):
            return family
        default:
            return nil
        }
    }

    public init?(rawValue: String) {
        let baseValue = rawValue.trimmingCharacters(in: .whitespaces)
        guard !baseValue.isEmpty else {
            return nil
        }
        switch NWEndpoint.Host(baseValue) {
        case .ipv4:
            self = .ip(baseValue, .v4)
        case .ipv6:
            self = .ip(baseValue, .v6)
        default:
            guard baseValue != PartoutLogger.redactedValue else {
                return nil
            }
            self = .hostname(baseValue)
        }
    }

    public init?(data: Data) {
        if let address = IPv4Address(data) {
            self = .ip(address.debugDescription, .v4)
        } else if let address = IPv6Address(data) {
            self = .ip(address.debugDescription, .v6)
        } else {
            return nil
        }
    }
}

extension Address: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension Address {
    public func network(with ipv4Mask: String) -> Address? {
        assert(family == .v4)
        guard let address = IPv4Address(rawValue),
              let mask = IPv4Address(ipv4Mask) else {
            return nil
        }
        let bytes = Data(zip(address.rawValue, mask.rawValue).map { $0 & $1 })
        guard let network = IPv4Address(bytes) else {
            return nil
        }
        return .ip(network.debugDescription, .v4)
    }

    public func network(with ipv6PrefixLength: Int) -> Address? {
        guard (0...128).contains(ipv6PrefixLength),
              let address = IPv6Address(rawValue) else {
            return nil
        }
        var bytes = address.rawValue
        let fullBytes = ipv6PrefixLength / 8
        let remainingBits = ipv6PrefixLength % 8
        if remainingBits == 0 {
            bytes.resetBytes(in: fullBytes..<bytes.count)
        } else {
            bytes[fullBytes] &= UInt8.max << (8 - remainingBits)
            bytes.resetBytes(in: (fullBytes + 1)..<bytes.count)
        }
        guard let network = IPv6Address(bytes) else {
            return nil
        }
        return .ip(network.debugDescription, .v6)
    }
}

extension Address: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? rawValue : PartoutLogger.redactedValue
    }
}
