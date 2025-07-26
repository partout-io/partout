// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

/// A ``/PartoutCore/TunnelEnvironment`` that stores data to `UserDefaults`.
public final class UserDefaultsEnvironment: TunnelEnvironment, @unchecked Sendable {
    private let profileId: Profile.ID?

    private let defaults: UserDefaults

    private let prefix: String

    public init(profileId: Profile.ID?, defaults: UserDefaults) {
        self.profileId = profileId
        self.defaults = defaults
        prefix = profileId.map {
            "\($0)."
        } ?? ""
    }

    public func setEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable {
        let fullKey = key.keyString.rawKey(prefix: prefix)
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: fullKey)
            pp_log_id(profileId, .core, .debug, "UserDefaultsEnvironment.set(\(fullKey)) -> \(value)")
        } catch {
            pp_log_id(profileId, .core, .error, "Unable to set environment key: \(fullKey) -> \(error)")
        }
    }

    public func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable {
        let fullKey = key.keyString.rawKey(prefix: prefix)
        do {
            guard let data = defaults.data(forKey: fullKey) else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            pp_log_id(profileId, .core, .error, "Unable to get environment key: \(fullKey) -> \(error)")
            return nil
        }
    }

    public func removeEnvironmentValue(forKey key: String) {
        let fullKey = key.rawKey(prefix: prefix)
        defaults.removeObject(forKey: fullKey)
        pp_log_id(profileId, .core, .debug, "UserDefaultsEnvironment.remove(\(fullKey))")
    }

    public func snapshot(excludingKeys excluded: Set<String>?) -> [String: Data] {
        var values = defaults.dictionaryRepresentation()
        if let excluded {
            let mappedExcluded = excluded.map {
                $0.rawKey(prefix: prefix)
            }
            values = values.filter {
                !mappedExcluded.contains($0.key)
            }
        }
        values = values.filter {
            $0.key.hasPrefix(prefix)
        }
        return values.reduce(into: [:]) {
            guard let data = $1.value as? Data else {
                return
            }
            let keyBegin = $1.key.index($1.key.startIndex, offsetBy: prefix.count)
            let unprefixedKey = $1.key[keyBegin..<$1.key.endIndex]
            $0[String(unprefixedKey)] = data
        }
    }

    public func reset() {
    }
}

private extension String {
    func rawKey(prefix: String) -> String {
        [prefix, self].joined()
    }
}
