// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_FOUNDATION_COMPAT

extension Registry {
    public func json(fromProfiles profiles: [Profile]) throws -> String {
        try RegistryJSONEncoder(self).encode(profiles.map(\.asCodableProfile))
    }

    public func json(fromProfile profile: Profile) throws -> String {
        try RegistryJSONEncoder(self).encode(profile.asCodableProfile)
    }

    public func profile(fromJSON json: String) throws -> Profile {
        try profile(fromString: json, decoder: RegistryJSONEncoder(self))
    }

    public func profiles(fromJSON json: String) throws -> [Profile] {
        try profiles(fromString: json, decoder: RegistryJSONEncoder(self))
    }

    // Tolerate older encoding
    public func fallbackProfile(fromString string: String, fallingBack: Bool = true) throws -> Profile {
        do {
            return try profile(fromJSON: string)
        } catch {
            guard fallingBack else {
                throw error
            }
            let decoded = try CodableProfileCoder().decodedProfile(from: string, with: self)
            return postDecodeBlock?(decoded) ?? decoded
        }
    }
}

private final class RegistryJSONEncoder: TextEncoder, TextDecoder {
    private let registry: Registry

    init(_ registry: Registry) {
        self.registry = registry
    }

    func encode<T>(_ value: T) throws -> String where T: Encodable {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding, "Not a UTF-8 input")
        }
        return json
    }

    func decode<T>(_ type: T.Type, string: String) throws -> T where T: Decodable {
        let decoder = JSONDecoder()
        decoder.userInfo = [.moduleDecoder: registry]
        guard let json = string.data(using: .utf8) else {
            throw PartoutError(.decoding, "Not a UTF-8 input")
        }
        return try decoder.decode(type, from: json)
    }
}

#endif
