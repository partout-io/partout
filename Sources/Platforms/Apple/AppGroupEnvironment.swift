//
//  AppGroupEnvironment.swift
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

/// A ``TunnelEnvironment`` that stores data to an App Group.
public final class AppGroupEnvironment: TunnelEnvironment, @unchecked Sendable {
    private let defaults: UserDefaults

    private let appGroup: String

    private let prefix: String

    public init(appGroup: String, prefix: String = "") {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            fatalError("No access to App Group: \(appGroup)")
        }
        self.defaults = defaults
        self.appGroup = appGroup
        self.prefix = prefix
    }

    public func setEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable {
        let fullKey = key.rawKey(prefix: prefix)
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: fullKey)
            pp_log(.core, .debug, "AppGroupEnvironment.set(\(fullKey)) -> \(value)")
        } catch {
            pp_log(.core, .error, "Unable to set environment key: \(fullKey) -> \(error)")
        }
    }

    public func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable {
        let fullKey = key.rawKey(prefix: prefix)
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

    public func removeEnvironmentValue<T>(forKey key: TunnelEnvironmentKey<T>) {
        let fullKey = key.rawKey(prefix: prefix)
        defaults.removeObject(forKey: fullKey)
        pp_log(.core, .info, "AppGroupEnvironment.remove(\(fullKey))")
    }

    public func reset() {
        defaults.removePersistentDomain(forName: appGroup)
    }
}

private extension TunnelEnvironmentKey {
    func rawKey(prefix: String) -> String {
        [prefix, string].joined()
    }
}
