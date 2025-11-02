// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Defines the communication protocol of an endpoint.
public struct EndpointProtocol: Hashable, Sendable {

    /// The socket type.
    public let socketType: IPSocketType

    /// The remote port.
    public let port: UInt16

    public init(_ socketType: IPSocketType, _ port: UInt16) {
        self.socketType = socketType
        self.port = port
    }
}

extension EndpointProtocol: RawRepresentable {
    public init?(rawValue: String) {
        let components = rawValue.components(separatedBy: ":")
        guard components.count == 2 else {
            return nil
        }
        guard let socketType = IPSocketType(rawValue: components[0]) else {
            return nil
        }
        guard let port = UInt16(components[1]) else {
            return nil
        }
        self.init(socketType, port)
    }

    public var rawValue: String {
        "\(socketType.rawValue):\(port)"
    }
}

extension EndpointProtocol: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension EndpointProtocol: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let proto = EndpointProtocol(rawValue: rawValue) else {
            throw PartoutError(.decoding)
        }
        self.init(proto.socketType, proto.port)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
