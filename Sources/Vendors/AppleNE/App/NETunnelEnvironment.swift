//
//  NETunnelEnvironment.swift
//  Partout
//
//  Created by Davide De Rosa on 5/6/25.
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

/// A ``/PartoutCore/TunnelEnvironmentReader`` that updates via Network Extension messaging.
public final class NETunnelEnvironment: TunnelEnvironmentReader, @unchecked Sendable {
    private let queue: DispatchQueue

    private weak var strategy: NETunnelStrategy?

    private let profileId: Profile.ID

    private let interval: TimeInterval

    private var latestEnvironment: TunnelEnvironmentReader?

    private var timerSubscription: Task<Void, Never>?

    public init(strategy: NETunnelStrategy, profileId: Profile.ID, interval: TimeInterval = 1.0) {
        queue = DispatchQueue(label: "NETunnelEnvironment.\(profileId)")
        self.strategy = strategy
        self.profileId = profileId
        self.interval = interval
        observeObjects()
    }

    public func environmentValue<T>(forKey key: TunnelEnvironmentKey<T>) -> T? where T: Decodable {
        queue.sync {
            latestEnvironment?.environmentValue(forKey: key)
        }
    }

    public func snapshot(excludingKeys excluded: Set<String>?) -> [String: Data] {
        queue.sync {
            latestEnvironment?.snapshot(excludingKeys: excluded) ?? [:]
        }
    }
}

private extension NETunnelEnvironment {
    func observeObjects() {
        timerSubscription = Task { [weak self] in
            while true {
                guard let self, let strategy else {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                do {
                    let output = try await strategy.sendMessage(.environment(), to: profileId)
                    switch output {
                    case .environment(let env):
                        latestEnvironment = env
                    default:
                        break
                    }
                    try await Task.sleep(interval: interval)
                } catch {
                    pp_log_id(profileId, .ne, .error, "Unable to fetch NE environment for \(profileId): \(error)")
                    return
                }
            }
        }
    }
}
