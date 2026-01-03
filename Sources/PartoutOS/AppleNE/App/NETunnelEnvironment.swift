// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A tunnel environment reader that updates via Network Extension messaging.
public final class NETunnelEnvironment: TunnelEnvironmentReader, @unchecked Sendable {
    private let queue: DispatchQueue

    private weak var strategy: NETunnelStrategy?

    private let profileId: Profile.ID

    private let interval: TimeInterval

    private var latestEnvironment: TunnelEnvironmentReader?

    private var timerSubscription: Task<Void, Never>?

    public init(strategy: NETunnelStrategy, profileId: Profile.ID, interval: TimeInterval = 1.0) {
        queue = DispatchQueue(label: "NETunnelEnvironment[\(profileId)]")
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
                    pp_log_id(profileId, .os, .error, "Unable to fetch NE environment for \(profileId): \(error)")
                    return
                }
            }
        }
    }
}
