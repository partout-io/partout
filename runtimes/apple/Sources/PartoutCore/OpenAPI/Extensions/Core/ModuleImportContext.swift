// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Protocol-specific options for importing a module.
public enum ModuleImportContext: Hashable, Sendable {
    case OpenVPN(passphrase: String?)
    case WireGuard
}

extension ModuleImportContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case passphrase
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ModuleType.self, forKey: .type) {
        case .OpenVPN:
            self = .OpenVPN(
                passphrase: try container.decodeIfPresent(String.self, forKey: .passphrase)
            )
        case .WireGuard:
            self = .WireGuard
        default:
            throw PartoutError(.decoding)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .OpenVPN(let passphrase):
            try container.encode(ModuleType.OpenVPN, forKey: .type)
            try container.encodeIfPresent(passphrase, forKey: .passphrase)
        case .WireGuard:
            try container.encode(ModuleType.WireGuard, forKey: .type)
        }
    }
}
