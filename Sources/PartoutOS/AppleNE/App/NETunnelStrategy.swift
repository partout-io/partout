// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension
import PartoutCore

/// A tunnel strategy based on `NETunnelProviderManager`.
public actor NETunnelStrategy {
    public enum Option: Sendable {
        case multiple
    }

    private let ctx: PartoutLoggerContext

    private let bundleIdentifier: String

    private let coder: NEProtocolCoder

    private let options: Set<Option>

    private let fingerprint: @Sendable (Profile) -> String?

    private nonisolated let managersSubject: CurrentValueStream<[Profile.ID: NETunnelProviderManager]>

    private var allManagers: [Profile.ID: NETunnelProviderManager] {
        didSet {
            managersSubject.send(allManagers)
        }
    }

    private var sourceTask: Task<Void, Never>?

    private var pendingSaveTask: PendingSaveTask?

    // TODO: #218/passepartout, support .multiple option after implementing in PTP
    public init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        source: AsyncStream<ProfilesEvent>,
        coder: NEProtocolCoder,
//        options: Set<Option> = []
        fingerprint: @escaping @Sendable (Profile) -> String?
    ) {
        pp_log(ctx, .os, .info, "NETunnelStrategy.init()")
        self.ctx = ctx
        self.bundleIdentifier = bundleIdentifier
        self.coder = coder
//        self.options = options
        self.fingerprint = fingerprint
        options = []
        managersSubject = CurrentValueStream([:])
        allManagers = [:]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNStatus),
            name: .NEVPNStatusDidChange,
            object: nil
        )

        sourceTask = Task { [weak self] in
            for await event in source {
                await self?.onSourceEvent(event)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - TunnelObservableStrategy

extension NETunnelStrategy: TunnelObservableStrategy {
    public func prepare(purge: Bool) async throws {
        allManagers = try await reloadAllManagers()
    }

    public func install(_ profile: Profile, connect: Bool, options: Sendable?) async throws {
        if connect, !self.options.contains(.multiple) {
            await disconnectCurrentManagers()
        }
        let nsOptions = options as? [String: NSObject]
        try await save(profile, forConnecting: connect, options: nsOptions)
    }

    public func uninstall(profileId: Profile.ID) async throws {
        try await remove(profileId: profileId)
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await saveAtomically(manager) {
            $0.isOnDemandEnabled = false
        }
        // XXX: Mitigate races where the on-demand flag, despite saveToPreferences(),
        // is not disabled yet, thus causing the tunnel to reconnect
        try await Task.sleep(for: .milliseconds(200))
        manager.connection.stopVPNTunnel()
        await manager.connection.waitForDisconnection()
    }

    public func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data? {
        guard let manager = allManagers[profileId],
              manager.connection.status.asTunnelStatus != .inactive else {
            return nil
        }
        try await manager.loadFromPreferences()
        guard let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public nonisolated var didUpdateActiveProfiles: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        let stream = activeProfilesStream
        return AsyncStream { [weak self] continuation in
            let task = Task { [weak self] in
                for await activeProfiles in stream {
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    guard !Task.isCancelled else {
                        pp_log(ctx, .os, .debug, "Cancelled NETunnelStrategy.didUpdateActiveProfiles")
                        break
                    }
                    pp_log(ctx, .os, .debug, "NETunnelStrategy.activeProfiles -> \(activeProfiles.values.description)")
                    continuation.yield(activeProfiles)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - CRUD

extension NETunnelStrategy {
    public func save(_ profile: Profile, forConnecting: Bool, options: [String: NSObject]?) async throws {
        profile.log(.os, .notice, withPreamble: "Encoded profile:")

        let proto = try coder.protocolConfiguration(from: profile)

        // Store custom data on the side
        proto.profileId = profile.id
        proto.fingerprint = fingerprint(profile)

        let manager = try await saveAtomically(profile.id) {
            $0.localizedDescription = profile.name
            $0.protocolConfiguration = proto

            let shouldEnableOnDemand: Bool
            if profile.isInteractive {
                shouldEnableOnDemand = false
            } else if let onDemandModule = profile.firstModule(ofType: OnDemandModule.self, ifActive: true) {
                let rules = onDemandModule.neRules(self.ctx)
                if !rules.isEmpty {
                    $0.onDemandRules = rules
                } else {
                    $0.onDemandRules = [NEOnDemandRuleConnect()]
                }
                shouldEnableOnDemand = true
            } else {
                shouldEnableOnDemand = false
            }

            // Do not alter these two flags unless connecting explicitly
            $0.isEnabled = forConnecting || $0.isEnabled
            $0.isOnDemandEnabled = (forConnecting || $0.isOnDemandEnabled) && shouldEnableOnDemand
        }

        // Track the new/updated manager
        allManagers[profile.id] = manager

        // Initiate a connection if requested
        if forConnecting {
            try manager.connection.startVPNTunnel(options: options)
        }
    }

    public func remove(profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await manager.removeFromPreferences()
        allManagers.removeValue(forKey: profileId)
    }
}

// MARK: - Source events

private extension NETunnelStrategy {
    func onSourceEvent(_ event: ProfilesEvent) async {
        switch event {
        case .snapshot(let profiles):
            await onSourceSnapshot(profiles)
        case .changes(let changes):
            for change in changes {
                await onSourceChange(change)
            }
        }
    }

    // FIXME: ###, This is kind of okay because it runs in the background. Doing save() while this is still ongoing, however, runs interleaved and may interfere with data integrity.
    func onSourceSnapshot(_ profiles: [Profile]) async {
        pp_log(ctx, .os, .debug, "Reconcile source snapshot: \(profiles.map(\.id))")
        var managers: [Profile.ID: NETunnelProviderManager]
        do {
            managers = try await reloadAllManagers()
        } catch {
            pp_log(ctx, .os, .fault, "Unable to reload managers: \(error)")
            return
        }

        // Copy to decouple
        let ctx = self.ctx

        // Clean up managers to begin with
        let profileIds = profiles.map(\.id)
        await withTaskGroup { group in
            for pair in managers {
                let manager = pair.value
                // Delete managers without ID
                guard let profileId = manager.profileId else {
                    group.addTask {
                        do {
                            pp_log(ctx, .os, .info, "Removing externally deleted manager (unknown)...")
                            try await manager.removeFromPreferences()
                            managers.removeValue(forKey: pair.key)
                        } catch {
                            pp_log(ctx, .os, .error, "Unable to remove unknown manager: \(error)")
                        }
                    }
                    continue
                }
                // Delete managers not backed by source
                guard profileIds.contains(profileId) else {
                    group.addTask {
                        do {
                            pp_log(ctx, .os, .info, "Removing externally deleted manager (\(profileId))...")
                            try await manager.removeFromPreferences()
                            managers.removeValue(forKey: pair.key)
                        } catch {
                            pp_log(ctx, .os, .error, "Unable to remove manager \(profileId): \(error)")
                        }
                    }
                    continue
                }
            }
        }

        // New saves are enqueued AFTER this task
        pp_log(ctx, .os, .info, "Saving \(profiles.count) profiles...")
        let startDate = Date()
        var actuallySaved = 0
        await withTaskGroup { group in
            for profile in profiles {
                // If the profile is associated with a manager, ensure that
                // it truly requires an update by comparing fingerprints
                if let manager = managers[profile.id], let fp = manager.fingerprint {
                    guard fp != fingerprint(profile) else {
                        pp_log(ctx, .os, .debug, "Manager \(profile.id) is up-to-date (fingerprint matches)")
                        actuallySaved += 1
                        continue
                    }
                }
                pp_log(ctx, .os, .info, "Manager \(profile.id) requires update (fingerprint differs)")
                group.addTask {
                    // Updating manager.fingerprint will prevent further reconciliations
                    do {
                        try await self.save(profile, forConnecting: false, options: [:])
                        actuallySaved += 1
                    } catch {
                        pp_log(ctx, .os, .error, "Unable to save profile \(profile.id): \(error)")
                    }
                }
            }
        }
        let elapsed = -startDate.timeIntervalSinceNow
        pp_log(ctx, .os, .info, "Saved \(actuallySaved)/\(profiles.count) profiles in: \(elapsed)")
    }

    func onSourceChange(_ change: ProfilesEvent.Change) async {
        switch change {
        case .upsert(let profile):
            pp_log(ctx, .os, .info, "Source upsert: \(profile.id)")
            do {
                try await save(
                    profile,
                    forConnecting: false,
                    options: [:]
                )
            } catch {
                pp_log(ctx, .os, .error, "Unable to save profile \(profile.id): \(error)")
            }
        case .remove(let profileId):
            pp_log(ctx, .os, .info, "Source remove: \(profileId)")
            do {
                try await remove(profileId: profileId)
            } catch {
                pp_log(ctx, .os, .error, "Unable to remove profile \(profileId): \(error)")
            }
        }
    }
}

// MARK: - Notifications

private extension NETunnelStrategy {
    @objc
    nonisolated func onVPNStatus(_ notification: Notification) {
        guard let connection = notification.object as? NETunnelProviderSession,
              let manager = connection.manager as? NETunnelProviderManager,
              manager.tunnelBundleIdentifier == bundleIdentifier,
              let profileId = manager.tunnelProtocol?.profileId else {
            return
        }
//        pp_log(ctx, .os, .debug, "NEVPNStatusDidChange: \(notification)")
        pp_log(ctx, .os, .debug, "NEVPNStatus(\(profileId)) -> \(connection.status.rawValue)")
        Task {
            await updateCurrentManagersIfNeeded(with: manager, profileId: profileId)
        }
    }
}

// MARK: - Concurrency

private extension NETunnelStrategy {
    func saveAtomically(
        _ profileId: Profile.ID,
        block: @escaping @Sendable (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        try await saveAtomically(
            self.allManagers[profileId] ?? NETunnelProviderManager(),
            block: block
        )
    }

    @discardableResult
    func saveAtomically(
        _ managerBlock: @escaping @autoclosure () -> NETunnelProviderManager,
        block: @escaping @Sendable (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        while let pendingSaveTask {
            do {
                try await pendingSaveTask.task.value
                clearPendingSaveTask(pendingSaveTask)
            } catch {
                clearPendingSaveTask(pendingSaveTask)
                throw error
            }
        }

        let manager = managerBlock()
        let pendingSaveTask = PendingSaveTask(task: Task { @Sendable in
            try await manager.loadFromPreferences()
            try Task.checkCancellation()
            block(manager)
            try Task.checkCancellation()
            try await manager.saveToPreferences()
        })
        self.pendingSaveTask = pendingSaveTask

        do {
            try await pendingSaveTask.task.value
            clearPendingSaveTask(pendingSaveTask)
        } catch {
            clearPendingSaveTask(pendingSaveTask)
            throw error
        }
        return manager
    }

    func clearPendingSaveTask(_ pendingSaveTask: PendingSaveTask) {
        guard self.pendingSaveTask?.id == pendingSaveTask.id else {
            return
        }
        self.pendingSaveTask = nil
    }

    func disconnectCurrentManagers() async {
        await withTaskGroup(of: Void.self) { group in
            allManagers.forEach { pair in
                let status = pair.value.connection.status.asTunnelStatus
                guard status != .inactive || pair.value.isOnDemandEnabled == true else {
                    return
                }
                group.addTask { [weak self] in
                    guard let self else {
                        return
                    }
                    pp_log(ctx, .os, .notice, "Disconnect from \(pair.key)...")
                    do {
                        try await disconnect(from: pair.key)
                    } catch {
                        pp_log(ctx, .os, .error, "Unable to disconnect from \(pair.key): \(error)")
                    }
                    pp_log(ctx, .os, .notice, "Disconnection of \(pair.key) complete!")
                }
            }
        }
    }
}

private struct PendingSaveTask: Sendable {
    let id = UniqueID()
    let task: Task<Void, Error>
}

// MARK: - Active managers

private extension NETunnelStrategy {
    nonisolated var activeProfilesStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        let stream = managersSubject.subscribe()
        let mappedStream: AsyncStream<[Profile.ID: TunnelSnapshot]>

        if options.contains(.multiple) {
            mappedStream = stream
                .map {
                    // Active managers are those ranked > 0
                    $0.filter {
                        $0.value.rank > 0
                    }
                    .compactMapValues(\.asSnapshot)
                }
        } else {
            mappedStream = stream
                .map {
                    // Active manager is the max ranked
                    let maxRank = $0.max {
                        $0.value.rank < $1.value.rank
                    }?.value.rank ?? 0

                    // If max rank is 0, no manager is active
                    guard maxRank > 0 else {
                        return [:]
                    }

                    // Return the max ranked manager
                    let filtered = $0.filter {
                        $0.value.rank == maxRank
                    }
                    // There might be a moment where 2 managers may be enabled at the same
                    // time, e.g., while switching from one to another one. We should
                    // tolerate this scenario.
                    assert(filtered.count <= 2, "Max ranked manager must be at most two")
                    return filtered.compactMapValues(\.asSnapshot)
                }
        }

        return mappedStream.removeDuplicates()
    }

    func reloadAllManagers() async throws -> [Profile.ID: NETunnelProviderManager] {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        defer {
            logManagers()
        }
        return await withTaskGroup { group in
            managers.reduce(into: [:]) { map, manager in
                guard manager.tunnelBundleIdentifier == bundleIdentifier else {
                    group.addTask {
                        try? await manager.removeFromPreferences()
                    }
                    return
                }
                guard let profileId = manager.tunnelProtocol?.profileId else {
                    group.addTask {
                        try? await manager.removeFromPreferences()
                    }
                    return
                }
                map[profileId] = manager
            }
        }
    }

    func updateCurrentManagersIfNeeded(with manager: NETunnelProviderManager, profileId: Profile.ID) {
        // Deletion
        if allManagers.keys.contains(profileId), manager.connection.status == .invalid {
            allManagers.removeValue(forKey: profileId)
        }
        // Update
        else {
            allManagers[profileId] = manager
        }
    }

    func logManagers() {
        if !allManagers.isEmpty {
            pp_log(ctx, .os, .debug, "NETunnelStrategy.allManagers:")
        } else {
            pp_log(ctx, .os, .debug, "NETunnelStrategy.allManagers: none")
        }
        allManagers.values.forEach {
            guard let profileId = $0.tunnelProtocol?.profileId else {
                return
            }
            pp_log(ctx, .os, .debug, "\t\($0.localizedDescription ?? "")(\(profileId)): isEnabled=\($0.isEnabled), isOnDemandEnabled=\($0.isOnDemandEnabled), status=\($0.connection.status), rank=\($0.rank)")
        }
    }
}

private extension NETunnelProviderManager {
    var rank: Int {
#if os(iOS) || os(tvOS)
        // Only one profile at a time is enabled on iOS/tvOS
        if isEnabled {
            return isOnDemandEnabled ? .max : .max - 1
        }
#endif
        if ![.disconnected, .invalid].contains(connection.status) {
            return 2
        }
        if isOnDemandEnabled {
            return 1
        }
        return 0
    }
}

// MARK: - Profile metadata

private enum CustomProviderKey: String {
    case profileId
    case fingerprint

    var key: String {
        "CustomProviderKey.\(rawValue)"
    }
}

private extension NETunnelProviderManager {
    var profileId: Profile.ID? {
        tunnelProtocol?.profileId
    }

    var fingerprint: String? {
        tunnelProtocol?.fingerprint
    }
}

private extension NETunnelProviderProtocol {
    var profileId: UniqueID? {
        get {
            guard let uuidString = providerConfiguration?[CustomProviderKey.profileId.key] as? String else {
                return nil
            }
            return UniqueID(uuidString: uuidString)
        }
        set {
            var cfg = providerConfiguration ?? [:]
            cfg[CustomProviderKey.profileId.key] = newValue?.uuidString
            providerConfiguration = cfg
        }
    }

    var fingerprint: String? {
        get {
            providerConfiguration?[CustomProviderKey.fingerprint.key] as? String
        }
        set {
            var cfg = providerConfiguration ?? [:]
            cfg[CustomProviderKey.fingerprint.key] = newValue
            providerConfiguration = cfg
        }
    }
}

private extension NETunnelProviderManager {
    var tunnelProtocol: NETunnelProviderProtocol? {
        protocolConfiguration as? NETunnelProviderProtocol
    }

    var tunnelBundleIdentifier: String? {
        tunnelProtocol?.providerBundleIdentifier
    }
}

// MARK: - Helpers

private extension NEVPNConnection {
    func waitForDisconnection() async {
        if status == .disconnected {
            return
        }
        for await notification in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
            guard let connection = notification.object as? NETunnelProviderSession,
                  connection === self else {
                continue
            }
            if [.disconnected, .invalid].contains(connection.status) {
                return
            }
        }
    }
}

extension NETunnelProviderManager: @retroactive @unchecked Sendable {
}

private extension NETunnelProviderManager {
    var asSnapshot: TunnelSnapshot? {
        guard let profileId else {
            return nil
        }
        let status = connection.status.asTunnelStatus
        let isEnabled = isEnabled && (isOnDemandEnabled || status != .inactive)
        return TunnelSnapshot(
            id: profileId,
            isEnabled: isEnabled,
            status: status,
            onDemand: isEnabled && isOnDemandEnabled
        )
    }
}

private extension NEVPNStatus {
    var asTunnelStatus: TunnelStatus {
        switch self {
        case .connecting, .reasserting:
            return .activating
        case .connected:
            return .active
        case .disconnecting:
            return .deactivating
        case .disconnected, .invalid:
            return .inactive
        @unknown default:
            return .inactive
        }
    }
}
