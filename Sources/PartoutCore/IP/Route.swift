// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents a  route in the routing table.
public struct Route: Hashable, Codable, Sendable {
    /// The destination subnet or `nil` if default.
    public let destination: Subnet?

    /// The address of the gateway (falls back to global gateway).
    public let gateway: Address?

    /// `true` if default destination.
    public var isDefault: Bool {
        destination == nil
    }

    public init(_ destination: Subnet?, _ gateway: Address?) {
        self.destination = destination
        self.gateway = gateway
    }

    public init(defaultWithGateway gateway: Address?) {
        destination = nil
        self.gateway = gateway
    }
}

extension Route: CustomDebugStringConvertible {
    public var debugDescription: String {
        "{\(destination?.description ?? "default") \(gateway?.description ?? "*")}"
    }
}
