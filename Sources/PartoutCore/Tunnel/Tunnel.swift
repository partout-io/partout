// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Manages a tunnel and observes its status.
public actor Tunnel: TunnelProtocol {
    private let ctx: PartoutLoggerContext

    private let strategy: TunnelObservableStrategy

    private let updateInterval: TimeInterval

    private var strategySnapshots: [Profile.ID: TunnelSnapshot]

    private let snapshotsSubject: CurrentValueStream<[Profile.ID: TunnelSnapshot]>

    private let environmentFactory: (Profile.ID) -> TunnelEnvironmentReader

    private var environments: [Profile.ID: TunnelEnvironmentReader]

    private var pendingInstall: Task<Void, Error>?

    private var subscriptions: [Task<Void, Never>]

    public init(
        _ ctx: PartoutLoggerContext,
        strategy: TunnelObservableStrategy,
        updateInterval: TimeInterval = 1.0,
        environmentFactory: @escaping (Profile.ID) -> TunnelEnvironmentReader
    ) {
        self.ctx = ctx
        self.strategy = strategy
        self.updateInterval = updateInterval
        self.environmentFactory = environmentFactory
        strategySnapshots = [:]
        snapshotsSubject = CurrentValueStream([:])
        environments = [:]
        subscriptions = []
#if swift(<6.0)
        observeObjects()
#endif
    }
}

// MARK: - TunnelStrategy

extension Tunnel: TunnelStrategy {
    public func prepare(purge: Bool) async throws {
#if swift(>=6.0)
        observeObjects()
#endif
        pp_log(ctx, .core, .info, "Prepare tunnel (purge: \(purge))...")
        try await strategy.prepare(purge: purge)
    }

    public func install(_ preProfile: Profile, connect: Bool, options: Sendable?) async throws {
        guard !preProfile.activeModulesIds.isEmpty else {
            throw PartoutError(.noActiveModules)
        }
        if let pendingInstall, !pendingInstall.isCancelled {
            pendingInstall.cancel()
            try? await pendingInstall.value
        }
        guard !Task.isCancelled else {
            pp_log(ctx, .core, .info, "Cancelled installation of profile \(profile.id)")
            return
        }
        pendingInstall = Task {
            pp_log(ctx, .core, .info, "Install profile \(profile.id)...")
            try await strategy.install(profile, connect: connect, options: options)
            guard !Task.isCancelled else {
                pp_log(ctx, .core, .info, "Cancelled installation of profile \(profile.id)")
                return
            }
        }
        try await pendingInstall?.value
        pendingInstall = nil
    }

    public func uninstall(profileId: Profile.ID) async throws {
        pp_log(ctx, .core, .info, "Uninstall profile \(profileId)...")
        try await strategy.uninstall(profileId: profileId)
        environments.removeValue(forKey: profileId)
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        pp_log(ctx, .core, .info, "Disconnect profile \(profileId)...")
        try await strategy.disconnect(from: profileId)
    }

    public func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data? {
        pp_log(ctx, .core, .info, "Send message to profile \(profileId)...")
        return try await strategy.sendMessage(message, to: profileId)
    }
}

extension Tunnel {
    public func install(_ profile: Profile, connect: Bool) async throws {
        try await install(profile, connect: connect, options: nil)
    }
}

// MARK: - State

extension Tunnel {
    public private(set) nonisolated var snapshots: [Profile.ID: TunnelSnapshot] {
        get {
            snapshotsSubject.value
        }
        set {
            snapshotsSubject.send(newValue)
        }
    }

    public nonisolated var snapshotsStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        snapshotsSubject.subscribe()
    }

    public func allEnvironments() -> [Profile.ID: TunnelEnvironmentReader] {
        environments
    }

    public func environment(for profileId: Profile.ID) -> TunnelEnvironmentReader? {
        environments[profileId]
    }
}

// MARK: Single profile

#if os(iOS) || os(tvOS)
extension Tunnel {
    public var snapshot: TunnelSnapshot? {
        snapshots.first?.value
    }

    public var status: TunnelStatus {
        snapshot?.status ?? .inactive
    }

    public func sendMessage(_ message: Message.Input) async throws -> Message.Output? {
        guard let profileId = snapshots.keys.first else { return nil }
        return try await sendMessage(message, to: profileId)
    }
}
#endif

// MARK: - Observation

private extension Tunnel {
    func observeObjects() {
#if swift(>=6.0)
        // Subscribe once
        guard subscriptions.isEmpty else { return }
#endif
        let strategySubscription = Task { [weak self] in
            guard let ctx = self?.ctx else { return }
            guard let stream = self?.strategy.didUpdateActiveProfiles else { return }
            for await snapshots in stream {
                guard let self else { break }
                guard !Task.isCancelled else { break }
                await handleStrategySnapshots(snapshots)
            }
            pp_log(ctx, .core, .debug, "Cancelled Tunnel.strategy.didUpdateActiveProfiles (observed)")
        }
        let timerSubscription = Task { [weak self] in
            guard let ctx = self?.ctx else { return }
            while true {
                guard let self else { break }
                guard !Task.isCancelled else { break }
                await refreshSnapshotEnvironments()
                try? await Task.sleep(interval: updateInterval)
            }
            pp_log(ctx, .core, .debug, "Cancelled Tunnel.timerSubscription")
        }
        subscriptions = [strategySubscription, timerSubscription]
    }

    func handleStrategySnapshots(_ snapshots: [Profile.ID: TunnelSnapshot]) {
        strategySnapshots = snapshots
        publishSnapshots()
    }

    func refreshSnapshotEnvironments() {
        publishSnapshots()
    }

    func publishSnapshots() {
        pp_log(ctx, .core, .info, "Snapshots: \(strategySnapshots.values.description)")
        let activeIds = strategySnapshots.keys
        // Create new environments if needed
        for profileId in activeIds {
            if environments[profileId] == nil {
                environments[profileId] = environmentFactory(profileId)
            }
        }
        // Destroy environments no longer present
        environments = environments.filter {
            activeIds.contains($0.key)
        }
        // Notify .snapshotsStream observers now
        let enriched = strategySnapshots.mapValues {
            guard let env = environments[$0.id] else { return $0 }
            return $0.with(environment: env.snapshot)
        }
        guard enriched != snapshots else { return }
        snapshots = enriched
    }
}
