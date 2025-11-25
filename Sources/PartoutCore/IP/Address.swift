// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A hostname or IP address.
@frozen
public enum Address: Hashable, Codable, Sendable {
    case ip(String, _ family: Family)

    case hostname(String)
}

extension Address: RawRepresentable {

    @frozen
    public enum Family: Sendable {
        case v4

        case v6
    }

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
        switch baseValue.addressFamily {
        case .v4:
            self = .ip(baseValue, .v4)
        case .v6:
            self = .ip(baseValue, .v6)
        default:
            guard baseValue != JSONEncoder.redactedValue else {
                return nil
            }
            self = .hostname(baseValue)
        }
    }

    public init?(data: Data) {
        switch data.count {
        case 4:
            let comps = data.map {
                UInt8($0).description
            }
            self = .ip(comps.joined(separator: "."), .v4)

        case 16:
            let comps = data.map {
                String(format: "%.02x", $0)
            }
            let quadComps = comps.joined().components(withLength: 4)
            self = .ip(quadComps.joined(separator: ":"), .v6)

        default:
            return nil
        }
    }
}

private extension String {
    func components(withLength length: Int) -> [String] {
        stride(from: 0, to: count, by: length)
            .map {
                let start = index(startIndex, offsetBy: $0)
                let end = index(start, offsetBy: length, limitedBy: endIndex) ?? endIndex
                return String(self[start..<end])
            }
    }
}

extension Address: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

// MARK: - Networks

extension Address {
    public func network(with ipv4Mask: String) -> Address? {
        assert(family == .v4)
        let dstLength = Int(INET_ADDRSTRLEN)
        var dst: [CChar] = Array(repeating: .zero, count: dstLength)
        let result = rawValue.utf8CString.withUnsafeBytes { addrPtr in
            ipv4Mask.utf8CString.withUnsafeBytes { netmaskPtr in
                dst.withUnsafeMutableBytes { dstPtr in
                    pp_addr_network_v4(
                        dstPtr.baseAddress,
                        dstLength,
                        addrPtr.baseAddress,
                        netmaskPtr.baseAddress
                    )
                }
            }
        }
        guard result != 0 else {
            return nil
        }
        let networkString = dst.string
        return Address(rawValue: networkString)
    }

    public func network(with ipv6PrefixLength: Int) -> Address? {
        let dstLength = Int(INET6_ADDRSTRLEN)
        var dst: [CChar] = Array(repeating: .zero, count: dstLength)
        let result = rawValue.utf8CString.withUnsafeBytes { addrPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                pp_addr_network_v6(
                    dstPtr.baseAddress,
                    dstLength,
                    addrPtr.baseAddress,
                    Int32(ipv6PrefixLength)
                )
            }
        }
        guard result != 0 else {
            return nil
        }
        let networkString = dst.string
        return Address(rawValue: networkString)
    }
}

// MARK: - Validation

private extension CharacterSet {
    static let nonIPv4: CharacterSet = .decimalDigits
        .union(.init(charactersIn: "."))
        .inverted

    static let nonDecimal: CharacterSet = .decimalDigits
        .inverted

    static let nonHexadecimal: CharacterSet = .decimalDigits
        .union(.init(charactersIn: "abcdefABCDEF"))
        .inverted
}

private extension String {
    var addressFamily: Address.Family? {
        let cFamily = pp_addr_family_of(cString(using: .utf8))
        switch cFamily {
        case PPAddrFamilyV4:
            return .v4
        case PPAddrFamilyV6:
            return .v6
        default:
            return nil
        }
    }
}

// MARK: - SensitiveDebugStringConvertible

extension Address: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? rawValue : JSONEncoder.redactedValue
    }
}
