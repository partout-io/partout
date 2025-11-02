// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``TunnelEnvironmentReader`` made of immutable values.
public struct StaticTunnelEnvironment: TunnelEnvironmentReader, Hashable, Codable, Sendable {
    private let profileId: Profile.ID?

    private let values: [String: Data]

    public init(profileId: Profile.ID?, values: [String: Data]) {
        self.profileId = profileId
        self.values = values
    }

    public func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable {
        do {
            return try values.decode(T.self, forKey: key.keyString)
        } catch {
            pp_log_id(profileId, .core, .error, "Unable to decode environment key '\(key.keyString)': \(error)")
            return nil
        }
    }

    public func snapshot(excludingKeys excluded: Set<String>?) -> [String: Data] {
        if let excluded {
            return values.filter {
                !excluded.contains($0.key)
            }
        }
        return values
    }
}
