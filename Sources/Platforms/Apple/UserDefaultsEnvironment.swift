//
//  UserDefaultsEnvironment.swift
//  Partout
//
//  Created by Davide De Rosa on 4/1/24.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import PartoutCore

/// A ``TunnelEnvironment`` that stores data to `UserDefaults`.
public final class UserDefaultsEnvironment: TunnelEnvironment, @unchecked Sendable {
    private let defaults: UserDefaults

    private let prefix: String

    public init(defaults: UserDefaults, prefix: String = "") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func setEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable {
        let fullKey = key.keyString.rawKey(prefix: prefix)
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: fullKey)
            pp_log(.core, .debug, "UserDefaultsEnvironment.set(\(fullKey)) -> \(value)")
        } catch {
            pp_log(.core, .error, "Unable to set environment key: \(fullKey) -> \(error)")
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
            pp_log(.core, .error, "Unable to get environment key: \(fullKey) -> \(error)")
            return nil
        }
    }

    public func removeEnvironmentValue(forKey key: String) {
        let fullKey = key.rawKey(prefix: prefix)
        defaults.removeObject(forKey: fullKey)
        pp_log(.core, .debug, "UserDefaultsEnvironment.remove(\(fullKey))")
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
