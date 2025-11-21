// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import PartoutCore_C

/// An IPv4/v6 subnet.
public struct Subnet: Hashable, Codable, Sendable {

    /// The subnet address.
    public let address: Address

    /// The prefix (0-8 for IPv4, 0-128 for IPv6).
    public let prefixLength: Int

    /// The classic IPv4 netmask.
    public var ipv4Mask: String {
        guard case .ip(_, let family) = address else {
            preconditionFailure()
        }
        precondition(family == .v4)
        return prefixLength.asNetworkMask
    }

    public init(_ rawAddress: String, _ prefixLength: Int) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError.invalidFields(["rawAddress": rawAddress])
        }
        switch address.family {
        case .v4:
            guard prefixLength <= 32 else {
                throw PartoutError.invalidFields(["rawAddress": rawAddress])
            }
        case .v6:
            guard prefixLength <= 128 else {
                throw PartoutError.invalidFields(["rawAddress": rawAddress])
            }
        default:
            throw PartoutError.invalidFields(["rawAddress": rawAddress])
        }
        // Should never fail because the preconditions are checked here
        self.init(address, prefixLength)!
    }

    public init(_ rawAddress: String, _ ipv4Mask: String) throws {
        try self.init(rawAddress, ipv4Mask.asPrefixLength)
    }

    public init?(_ address: Address) {
        switch address.family {
        case .v4:
            self.init(address, 32)
        case .v6:
            self.init(address, 128)
        default:
            preconditionFailure("Missing address family")
        }
    }

    public init?(_ address: Address, _ prefixLength: Int) {
        guard case .ip(_, let family) = address else {
            preconditionFailure()
        }
        let maxPrefixLength = family == .v6 ? 128 : 32
        guard prefixLength >= 0 && prefixLength <= maxPrefixLength else {
            return nil
        }
        self.address = address
        self.prefixLength = prefixLength
    }
}

extension Subnet: RawRepresentable {
    public var rawValue: String {
        return "\(address)/\(prefixLength)"
    }

    public init?(rawValue: String) {
        let comps = rawValue.components(separatedBy: "/")
        switch comps.count {
        case 1:
            // Address only, assumes full prefix (32/128)
            guard let addr = Address(rawValue: comps[0]), addr.isIPAddress else { return nil }
            self.init(addr)
        case 2:
            // Address and prefix
            guard let addr = Address(rawValue: comps[0]), addr.isIPAddress else { return nil }
            guard let prefixLength = Int(comps[1]) else { return nil }
            self.init(addr, prefixLength)
        default:
            return nil
        }
    }
}

extension Subnet: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

// MARK: - SensitiveDebugStringConvertible

extension Subnet: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription)/\(prefixLength)"
    }
}

// MARK: - Helpers

private extension String {
    var asPrefixLength: Int {
        var n = UInt32()
        inet_pton(AF_INET, self, &n)
        n = pp_swap_big32_to_host(n)
        var i = 0
        while n > 0 {
            if n & 1 == 1 {
                i += 1
            }
            n >>= 1
        }
        return i
    }
}

private extension Int {
    var asNetworkMask: String {
        guard self > 0 else {
            return "0.0.0.0"
        }
        let mask = (0xffffffff << (32 - self)) & 0xffffffff
        return "\(mask >> 24).\((mask >> 16) & 0xff).\((mask >> 8) & 0xff).\(mask & 0xff)"
    }
}
