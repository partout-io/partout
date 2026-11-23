// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Encodes and decodes profiles using their tagged JSON representation.
public final class BasicProfileCoder: ProfileCoder {
    public init() {}

    public func string(fromProfile profile: Profile) throws -> String {
        try JSONEncoder.shared().encodeJSON(profile.asTaggedProfile)
    }

    public func profile(fromString string: String) throws -> Profile {
        guard let data = string.data(using: .utf8) else {
            throw PartoutError(.decoding)
        }
        let tagged = try JSONDecoder.shared().decode(TaggedProfile.self, from: data)
        return try tagged.asProfile()
    }
}
