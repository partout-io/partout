// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Combine)
import Combine

extension Tunnel: ObservableObject {
}
#endif

/// Manages a tunnel and observes its status.
@MainActor
public final class Tunnel {
    private let ctx: PartoutLoggerContext

    private let strategy: TunnelObservableStrategy

    private let activeProfilesSubject: CurrentValueStream<[Profile.ID: TunnelActiveProfile]>

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
        activeProfilesSubject = CurrentValueStream([:])
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
}

// MARK: - State

extension Tunnel {
    public private(set) var activeProfiles: [Profile.ID: TunnelActiveProfile] {
        get {
            activeProfilesSubject.value
        }
        set {
#if canImport(Combine)
            objectWillChange.send()
#endif
            activeProfilesSubject.send(newValue)
        }
    }

    public var activeProfilesStream: AsyncStream<[Profile.ID: TunnelActiveProfile]> {
        activeProfilesSubject.subscribe()
    }

    public func environment(for profileId: Profile.ID) -> TunnelEnvironmentReader? {
        environments[profileId]
    }
}

// MARK: Single profile

#if os(iOS) || os(tvOS)
extension Tunnel {
    public var activeProfile: TunnelActiveProfile? {
        activeProfiles.first?.value
    }

    public var status: TunnelStatus {
        activeProfile?.status ?? .inactive
    }
}
#endif

// MARK: - Observation

private extension Tunnel {
    func observeObjects() {
        strategySubscription?.cancel()
        strategySubscription = Task { [weak self] in
            guard let self else {
                return
            }
            for await activeProfiles in strategy.didUpdateActiveProfiles {
                guard !Task.isCancelled else {
                    pp_log(ctx, .core, .debug, "Cancelled Tunnel.strategy.didUpdateActiveProfiles (observed)")
                    return
                }

                guard activeProfiles != self.activeProfiles else {
                    continue
                }
                pp_log(ctx, .core, .info, "Active profiles: \(activeProfiles.values.description)")
                let activeIds = activeProfiles.keys

                // create new environments if needed
                for profileId in activeIds {
                    if environments[profileId] == nil {
                        environments[profileId] = environmentFactory(profileId)
                    }
                }

                // destroy environments no longer present
                environments = environments.filter {
                    activeIds.contains($0.key)
                }

                // notify .activeProfilesStream observers now
                self.activeProfiles = activeProfiles
            }
        }
    }
}
