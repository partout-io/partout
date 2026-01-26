// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Represents an endpoint.
public struct Endpoint: Hashable, Codable, Sendable {
    /// The address.
    public let address: Address

    /// The port.
    public let port: UInt16

    public init(_ rawAddress: String, _ port: UInt16) throws {
        guard let address = Address(rawValue: rawAddress) else {
            throw PartoutError.invalidFields(["rawAddress": rawAddress])
        }
        self.init(address, port)
    }

    public init(_ address: Address, _ port: UInt16) {
        self.address = address
        self.port = port
    }
}

extension Endpoint: RawRepresentable {
    public var rawValue: String {
        "\(address):\(port)"
    }

    public init?(rawValue: String) {
        guard let indexOfSeparator = rawValue.lastIndex(of: ":") else {
            return nil
        }
        guard indexOfSeparator != rawValue.endIndex else {
            return nil
        }
        let rawAddress = rawValue[rawValue.startIndex..<indexOfSeparator]
        let rawPort = rawValue[rawValue.index(indexOfSeparator, offsetBy: 1)..<rawValue.endIndex]
        guard let port = UInt16(rawPort) else {
            return nil
        }
        try? self.init(String(rawAddress), port)
    }
}

extension Endpoint: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

// MARK: - SensitiveDebugStringConvertible

extension Endpoint: SensitiveDebugStringConvertible {
    public func encode(to encoder: Encoder) throws {
        try encodeSensitiveDescription(to: encoder)
    }

    public func debugDescription(withSensitiveData: Bool) -> String {
        let addressDescription = address.debugDescription(withSensitiveData: withSensitiveData)
        return "\(addressDescription):\(port)"
    }
}
