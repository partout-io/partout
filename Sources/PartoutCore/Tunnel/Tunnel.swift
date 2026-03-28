// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Manages a tunnel and observes its status.
public actor Tunnel {
    private let ctx: PartoutLoggerContext

    private let strategy: TunnelObservableStrategy

    private let snapshotsSubject: CurrentValueStream<[Profile.ID: TunnelSnapshot]>

    private let environmentFactory: (Profile.ID) -> TunnelEnvironmentReader

    private var environments: [Profile.ID: TunnelEnvironmentReader]

    private var pendingInstall: Task<Void, Error>?

    private var strategySubscription: Task<Void, Never>?

    public init(
        _ ctx: PartoutLoggerContext,
        strategy: TunnelObservableStrategy,
        environmentFactory: @escaping (Profile.ID) -> TunnelEnvironmentReader
    ) {
        self.ctx = ctx
        self.strategy = strategy
        self.environmentFactory = environmentFactory
        snapshotsSubject = CurrentValueStream([:])
        environments = [:]
        observeObjects()
    }
}

// MARK: - TunnelStrategy

extension Tunnel: TunnelStrategy {
    public func prepare(purge: Bool) async throws {
        pp_log(ctx, .core, .info, "Prepare tunnel (purge: \(purge))...")
        try await strategy.prepare(purge: purge)
    }

    public func install(
        _ profile: Profile,
        connect: Bool,
        options: Sendable?,
        title: @escaping @Sendable (Profile) -> String
    ) async throws {
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
        pendingInstall = Task {
            pp_log(ctx, .core, .info, "Install profile \(profile.id)...")
            try await strategy.install(profile, connect: connect, options: options, title: title)
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
    public func install(
        _ profile: Profile,
        connect: Bool,
        title: @escaping @Sendable (Profile) -> String
    ) async throws {
        try await install(profile, connect: connect, options: nil, title: title)
    }

    public func sendMessage(_ message: Message.Input) async throws -> Message.Output? {
        guard let profileId = snapshots.keys.first else { return nil }
        return try await sendMessage(message, to: profileId)
    }
}

// MARK: - State

extension Tunnel {
    public private(set) var snapshots: [Profile.ID: TunnelSnapshot] {
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
}
#endif

// MARK: - Observation

private extension Tunnel {
    func observeObjects() {
        strategySubscription?.cancel()
        strategySubscription = Task { [weak self] in
            guard let self else { return }
            for await snapshots in strategy.didUpdateActiveProfiles {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled Tunnel.strategy.didUpdateActiveProfiles (observed)")
                    return
                }
                await handleNewSnapshots(snapshots)
            }
        }
    }

    func handleNewSnapshots(_ snapshots: [Profile.ID: TunnelSnapshot]) {
        guard snapshots != self.snapshots else {
            return
        }
        pp_log(ctx, .core, .info, "Snapshots: \(snapshots.values.description)")
        // Create new environments if needed
        let active = snapshots.filter(\.value.isActive)
        for item in active {
            let profileId = item.key
            if environments[profileId] == nil {
                environments[profileId] = environmentFactory(profileId)
            }
        }
        // Discard environments of inactive profiles
        environments = environments.filter {
            snapshots[$0.key]?.isActive == true
        }
        // Notify .snapshotsStream observers now
        self.snapshots = snapshots
    }
}
