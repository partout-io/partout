// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// A ``TunnelEnvironment`` that stores data in memory.
public final class SharedTunnelEnvironment: TunnelEnvironment, @unchecked Sendable {
    private let profileId: Profile.ID?

    private let queue: DispatchQueue

    private var values: [String: Data]

    public init(profileId: Profile.ID?, values: [String: Data] = [:]) {
        self.profileId = profileId
        queue = DispatchQueue(label: "SharedTunnelEnvironment.\(profileId?.uuidString ?? "<anonymous>")")
        self.values = values
    }

    public func setEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable {
        queue.sync {
            do {
                try values.encode(value, forKey: key.keyString)
            } catch {
                pp_log_id(profileId, .core, .error, "Unable to encode environment key '\(key.keyString)': \(error)")
            }
        }
    }

    public func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable {
        queue.sync {
            do {
                return try values.decode(T.self, forKey: key.keyString)
            } catch {
                pp_log_id(profileId, .core, .error, "Unable to decode environment key '\(key.keyString)': \(error)")
                return nil
            }
        }
    }

    public func removeEnvironmentValue(forKey key: String) {
        queue.sync {
            _ = values.removeValue(forKey: key)
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

    public func reset() {
        queue.sync {
            values.removeAll()
        }
    }
}
