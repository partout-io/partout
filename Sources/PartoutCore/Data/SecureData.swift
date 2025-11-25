// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// Wrapper of a byte array with safe encoding capabilities.
public struct SecureData: Hashable, Codable, @unchecked Sendable {
    private let innerData: [UInt8]

    public init?(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        self.init(data)
    }

    public init(_ data: Data) {
        innerData = [UInt8](data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        innerData = [UInt8](data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if encoder.shouldEncodeSensitiveData {
            try container.encode(Data(innerData))
        } else {
            try container.encode(JSONEncoder.redactedValue)
        }
    }
}

extension SecureData {
    public var count: Int {
        innerData.count
    }

    public func withOffset(_ offset: Int, count: Int) -> SecureData {
        SecureData(Data(innerData).subdata(offset: offset, count: count))
    }

    public func toData() -> Data {
        Data(innerData)
    }

    public func toHex() -> String {
        toData().toHex()
    }
}

extension SecureData: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? toHex() : JSONEncoder.redactedValue
    }
}
