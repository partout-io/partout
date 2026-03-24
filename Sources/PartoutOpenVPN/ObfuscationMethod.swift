// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPN {

    /// The obfuscation method.
    public enum ObfuscationMethod: Hashable, Codable, Sendable {

        /// XORs the bytes in each buffer with the given mask.
        case xormask(mask: SecureData)

        /// XORs each byte with its position in the packet.
        case xorptrpos

        /// Reverses the order of bytes in each buffer except for the first (abcde becomes aedcb).
        case reverse

        /// Performs several of the above steps (xormask -> xorptrpos -> reverse -> xorptrpos).
        case obfuscate(mask: SecureData)

        /// The optionally associated mask.
        public var mask: SecureData? {
            switch self {
            case .xormask(let mask):
                return mask

            case .obfuscate(let mask):
                return mask

            default:
                return nil
            }
        }
    }
}

// MARK: - Custom Codable

extension OpenVPN.ObfuscationMethod {
    enum Discriminator: String, Codable {
        case xormask
        case xorptrpos
        case reverse
        case obfuscate
    }

    enum CodingKeys: String, CodingKey {
        case type
        case mask
    }

    enum LegacyCodingKeys: String, CodingKey {
        case xormask
        case xorptrpos
        case reverse
        case obfuscate
    }

    enum LegacyMaskCodingKeys: String, CodingKey {
        case mask
    }

    public init(from decoder: any Decoder) throws {
        if let value = try Self.fromTagged(decoder: decoder) {
            self = value
            return
        }
        self = try Self.fromLegacy(decoder: decoder)
    }

    private static func fromTagged(decoder: any Decoder) throws -> Self? {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let discriminator = try container.decodeIfPresent(
            Discriminator.self,
            forKey: .type
        ) else {
            return nil
        }
        switch discriminator {
        case .xormask:
            let mask = try container.decode(SecureData.self, forKey: .mask)
            return .xormask(mask: mask)
        case .xorptrpos:
            return .xorptrpos
        case .reverse:
            return .reverse
        case .obfuscate:
            let mask = try container.decode(SecureData.self, forKey: .mask)
            return .obfuscate(mask: mask)
        }
    }

    private static func fromLegacy(decoder: any Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if container.contains(.xormask) {
            let map = try container.superDecoder(forKey: .xormask)
            let sub = try map.container(keyedBy: LegacyMaskCodingKeys.self)
            let mask = try sub.decode(SecureData.self, forKey: .mask)
            return .xormask(mask: mask)
        }
        if container.contains(.xorptrpos) {
            return .xorptrpos
        }
        if container.contains(.reverse) {
            return .reverse
        }
        if container.contains(.obfuscate) {
            let map = try container.superDecoder(forKey: .obfuscate)
            let sub = try map.container(keyedBy: LegacyMaskCodingKeys.self)
            let mask = try sub.decode(SecureData.self, forKey: .mask)
            return .obfuscate(mask: mask)
        }
        throw PartoutError(.decoding)
    }

    public func encode(to encoder: any Encoder) throws {
        // Legacy Swift encoding (incompatible with cross)
        if encoder.userInfo.usesLegacySwiftEncoding {
            var container = encoder.singleValueContainer()
            let map: [String: [String: String]]
            switch self {
            case .xormask(let mask):
                map = ["xormask": ["mask": mask.toData().base64EncodedString()]]
            case .xorptrpos:
                map = ["xorptrpos": [:]]
            case .reverse:
                map = ["reverse": [:]]
            case .obfuscate(let mask):
                map = ["obfuscate": ["mask": mask.toData().base64EncodedString()]]
            }
            try container.encode(map)
            return
        }

        // Tagged union (cross friendly)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let discriminator: Discriminator
        let mask: SecureData?
        switch self {
        case .xormask(let arg):
            discriminator = .xormask
            mask = arg
        case .xorptrpos:
            discriminator = .xorptrpos
            mask = nil
        case .reverse:
            discriminator = .reverse
            mask = nil
        case .obfuscate(let arg):
            discriminator = .obfuscate
            mask = arg
        }
        try container.encode(discriminator, forKey: .type)
        if let mask {
            try container.encode(mask, forKey: .mask)
        }
    }
}
