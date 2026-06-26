// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Manages a tunnel and observes its status.
public actor Tunnel {
    public typealias WillInstallBlock = @Sendable (_ profile: Profile) async throws -> Profile

    private let ctx: PartoutLoggerContext

    private let strategy: TunnelObservableStrategy

    private let refreshInterval: Int?

    private let willInstall: WillInstallBlock?

    private let environmentFactory: (Profile.ID) -> TunnelEnvironmentReader

    private var strategySnapshots: [Profile.ID: TunnelSnapshot]

    private let snapshotsSubject: CurrentValueStream<[Profile.ID: TunnelSnapshot]>

    private var environments: [Profile.ID: TunnelEnvironmentReader]

    private var pendingInstall: Task<Void, Error>?

    private var subscriptions: [Task<Void, Never>]

    public init(
        _ ctx: PartoutLoggerContext,
        strategy: TunnelObservableStrategy,
        refreshInterval: Int? = nil,
        willInstall: WillInstallBlock? = nil,
        environmentFactory: @escaping (Profile.ID) -> TunnelEnvironmentReader
    ) {
        self.ctx = ctx
        self.strategy = strategy
        self.refreshInterval = refreshInterval
        self.willInstall = willInstall
        self.environmentFactory = environmentFactory
        strategySnapshots = [:]
        snapshotsSubject = CurrentValueStream([:])
        environments = [:]
        subscriptions = []
    }

    deinit {
        pendingInstall?.cancel()
        subscriptions.forEach {
            $0.cancel()
        }
    }
}

// MARK: - TunnelStrategy

extension Tunnel: TunnelStrategy {
    public func prepare(purge: Bool) async throws {
        observeObjects()
        pp_log(ctx, .core, .info, "Prepare tunnel (purge: \(purge))...")
        try await strategy.prepare(purge: purge)
    }

    public func install(_ profile: Profile, connect: Bool, options: Sendable?) async throws {
        observeObjects()
        guard !profile.activeModulesIds.isEmpty else {
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
        // Optionally pre-process profile
        let postProfile: Profile
        if let willInstall {
            pp_log(ctx, .core, .info, "Pre-process profile \(profile.id) before installing")
            postProfile = try await willInstall(profile)
        } else {
            postProfile = profile
        }
        pendingInstall = Task {
            pp_log(ctx, .core, .info, "Install profile \(postProfile.id)...")
            try await strategy.install(postProfile, connect: connect, options: options)
            guard !Task.isCancelled else {
                pp_log(ctx, .core, .info, "Cancelled installation of profile \(postProfile.id)")
                return
            }
        }
        try await pendingInstall?.value
        pendingInstall = nil
    }

    public func uninstall(profileId: Profile.ID) async throws {
        observeObjects()
        pp_log(ctx, .core, .info, "Uninstall profile \(profileId)...")
        try await strategy.uninstall(profileId: profileId)
        environments.removeValue(forKey: profileId)
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        observeObjects()
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
        // Subscribe once
        guard subscriptions.isEmpty else { return }
        let ctx = self.ctx
        let strategyStream = strategy.didUpdateActiveProfiles
        var subscriptions: [Task<Void, Never>] = []
        subscriptions.append(Task { [weak self, ctx] in
            for await snapshots in strategyStream {
                guard !Task.isCancelled else { break }
                await self?.handleStrategySnapshots(snapshots)
            }
            pp_log(ctx, .core, .debug, "Cancelled Tunnel.strategy.didUpdateActiveProfiles (observed)")
        })
        if let refreshInterval {
            subscriptions.append(Task { [weak self] in
                guard let ctx = self?.ctx else { return }
                while true {
                    guard !Task.isCancelled else { break }
                    await self?.refreshSnapshotEnvironments()
                    try? await Task.sleep(milliseconds: refreshInterval)
                }
                pp_log(ctx, .core, .debug, "Cancelled Tunnel.timerSubscription")
            })
        }
        self.subscriptions = subscriptions
    }

    func handleStrategySnapshots(_ snapshots: [Profile.ID: TunnelSnapshot]) {
        strategySnapshots = snapshots
        pp_log(ctx, .core, .info, "Snapshots: \(strategySnapshots.values.description)")
        publishSnapshots()
    }

    func refreshSnapshotEnvironments() {
        publishSnapshots()
    }

    func publishSnapshots() {
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
