// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TaggedProfile/TaggedModule don't need any .userInfo
final class ProfileEncoderV3 {
    func encode(_ value: TaggedProfile) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding, "Not a UTF-8 output")
        }
        return json
    }

    func decode(_ string: String) throws -> TaggedProfile {
        let decoder = JSONDecoder()
        guard let json = string.data(using: .utf8) else {
            throw PartoutError(.decoding, "Not a UTF-8 input")
        }
        return try decoder.decode(TaggedProfile.self, from: json)
    }
}
