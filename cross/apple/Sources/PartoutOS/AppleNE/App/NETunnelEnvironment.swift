// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A tunnel environment reader that updates via Network Extension messaging.
public final class NETunnelEnvironment: TunnelEnvironmentReader, @unchecked Sendable {
    public typealias FetchBlock = @Sendable (Profile.ID) async throws -> StaticTunnelEnvironment?

    private let queue: DispatchQueue

    private let profileId: Profile.ID

    private let interval: TimeInterval

    private let fetchEnvironment: FetchBlock

    private var latestEnvironment: TunnelEnvironmentReader?

    private var timerSubscription: Task<Void, Never>?

    public init(
        profileId: Profile.ID,
        interval: TimeInterval = 1.0,
        fetchEnvironment: @escaping FetchBlock
    ) {
        queue = DispatchQueue(label: "NETunnelEnvironment[\(profileId)]")
        self.profileId = profileId
        self.interval = interval
        self.fetchEnvironment = fetchEnvironment
        observeObjects()
    }

    public func environmentData(forKey key: String) -> Data? {
        queue.sync {
            latestEnvironment?.environmentData(forKey: key)
        }
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
                guard let self else { return }
                guard !Task.isCancelled else { return }
                do {
                    latestEnvironment = try await fetchEnvironment(profileId)
                } catch {
                    pp_log_id(profileId, .os, .error, "Unable to fetch NE environment for \(profileId): \(error)")
                }
                try? await Task.sleep(interval: interval)
            }
        }
    }
}
