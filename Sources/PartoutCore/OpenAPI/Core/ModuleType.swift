// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Raw type univocally associated to each ``Module`` implementation.
public enum ModuleType: String, RawRepresentable, Identifiable, Hashable, Codable, Sendable {
    case Custom
    case DNS
    case HTTPProxy
    case IP
    case OnDemand
    case OpenVPN
    case Provider
    case WireGuard
    case Undefined

    public init(_ name: String) {
        let value = ModuleType(rawValue: name)
        self = value ?? .Undefined
    }

    public var id: String {
        rawValue
    }
}

extension ModuleType {

    // WARNING: retain this for legacy persisted profiles
    private enum CodingKeys: CodingKey {
        case name
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let name = try container.decode(String.self)
            self.init(name)
        } catch {
            // legacy encoding
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .name)
            self.init(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ModuleType: CustomDebugStringConvertible {
    public var debugDescription: String {
        rawValue
    }
}
