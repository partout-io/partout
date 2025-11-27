// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_implementationOnly import _PartoutCore_C

/// Aggregates an address and an ``EndpointProtocol``.
public struct ExtendedEndpoint: Hashable, Codable, Sendable {

    // XXX: simplistic match
    private static let rx = RegularExpression("^([^\\s]+):(UDP[46]?|TCP[46]?):(\\d+)$")

    public let address: Address

    public let proto: EndpointProtocol

    public init(_ rawAddress: String, _ proto: EndpointProtocol) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError.invalidFields(["rawAddress": rawAddress])
        }
        self.init(address, proto)
    }

    public init(_ address: Address, _ proto: EndpointProtocol) {
        self.address = address
        self.proto = proto
    }

    public var isIPv4: Bool {
        address.rawValue.withCString {
            pp_addr_family_of($0) == PPAddrFamilyV4
        }
    }

    public var isIPv6: Bool {
        address.rawValue.withCString {
            pp_addr_family_of($0) == PPAddrFamilyV6
        }
    }

    public var isHostname: Bool {
        !isIPv4 && !isIPv6
    }
}

extension ExtendedEndpoint: RawRepresentable {
    public init?(rawValue: String) {
        let components = Self.rx.groups(in: rawValue)
        guard components.count == 3 else {
            return nil
        }
        let rawAddress = components[0]
        guard let socketType = IPSocketType(rawValue: components[1]) else {
            return nil
        }
        guard let port = UInt16(components[2]) else {
            return nil
        }
        try? self.init(rawAddress, EndpointProtocol(socketType, port))
    }

    public var rawValue: String {
        "\(address):\(proto.socketType.rawValue):\(proto.port)"
    }
}

extension ExtendedEndpoint: CustomStringConvertible {
    public var description: String {
        "\(address):\(proto.rawValue)"
    }
}

// MARK: - SensitiveDebugStringConvertible

extension ExtendedEndpoint: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription):\(proto.rawValue)"
    }
}
