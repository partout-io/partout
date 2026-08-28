// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension

/// A tunnel strategy based on `NETunnelProviderManager`.
public actor NETunnelStrategy {
    private let ctx: PartoutLoggerContext

    private let bundleIdentifier: String

    private let source: AsyncStream<ProfilesEvent>

    private let coder: NEProtocolCoder

    private let preferences: NETunnelPreferences

    private let fingerprint: @Sendable (Profile) -> String?

    private nonisolated let managerSnapshotsSubject: CurrentValueStream<[Profile.ID: NETunnelManagerSnapshot]>

    private var allManagers: [Profile.ID: NETunnelProviderManager] {
        didSet {
            publishManagerSnapshots()
        }
    }

    private var sourceTask: Task<Void, Never>?

    private var mutationTail: Task<Void, Never>?

    public init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        source: AsyncStream<ProfilesEvent>,
        coder: NEProtocolCoder,
        fingerprint: @escaping @Sendable (Profile) -> String?
    ) {
        self.init(
            ctx,
            bundleIdentifier: bundleIdentifier,
            source: source,
            coder: coder,
            preferences: .live,
            fingerprint: fingerprint
        )
    }

    init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        source: AsyncStream<ProfilesEvent>,
        coder: NEProtocolCoder,
        preferences: NETunnelPreferences,
        fingerprint: @escaping @Sendable (Profile) -> String?
    ) {
        pp_log(ctx, .os, .info, "NETunnelStrategy.init()")
        self.ctx = ctx
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.coder = coder
        self.preferences = preferences
        self.fingerprint = fingerprint
        managerSnapshotsSubject = CurrentValueStream([:])
        allManagers = [:]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNStatus),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    deinit {
        sourceTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - TunnelObservableStrategy

extension NETunnelStrategy: TunnelObservableStrategy {
    public func prepare(purge: Bool) async throws {
        guard sourceTask == nil else {
            return
        }
        let source = self.source
        sourceTask = Task { [weak self] in
            for await event in source {
                guard let self else { return }
                await self.onSourceEvent(event)
            }
        }
    }

    public func install(_ profile: Profile, connect: Bool, options: Sendable?) async throws {
        try await withMutation { strategy in
            if connect {
                await strategy.disconnectCurrentManagers()
            }
            let nsOptions = options as? [String: NSObject]
            try await strategy.performSave(profile, forConnecting: connect, options: nsOptions)
        }
    }

    public func uninstall(profileId: Profile.ID) async throws {
        try await withMutation { strategy in
            try await strategy.performRemove(profileId: profileId)
        }
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        try await withMutation { strategy in
            try await strategy.performDisconnect(from: profileId)
        }
    }

    public func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data? {
        let session = try await withMutation { strategy in
            guard let manager = strategy.allManagers[profileId],
                  manager.connection.status.asTunnelStatus != .inactive else {
                return SendableProviderSession(nil)
            }
            try await strategy.preferences.load(manager)
            return SendableProviderSession(manager.connection as? NETunnelProviderSession)
        }
        guard let session = session.value else {
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
        let options = SendableTunnelOptions(options)
        try await withMutation { strategy in
            try await strategy.performSave(
                profile,
                forConnecting: forConnecting,
                options: options.value
            )
        }
    }

    public func remove(profileId: Profile.ID) async throws {
        try await withMutation { strategy in
            try await strategy.performRemove(profileId: profileId)
        }
    }
}

private extension NETunnelStrategy {
    func performSave(_ profile: Profile, forConnecting: Bool, options: [String: NSObject]?) async throws {
        profile.log(.core, .notice, withPreamble: "Encoded profile:")

        let proto = try coder.protocolConfiguration(from: profile)

        // Store custom data on the side
        proto.profileId = profile.id
        proto.fingerprint = fingerprint(profile)

        let manager = try await saveManager(profile.id) {
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

    func performRemove(profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await preferences.remove(manager)
        allManagers.removeValue(forKey: profileId)
    }
}

// MARK: - Source events

private extension NETunnelStrategy {
    func onSourceEvent(_ event: ProfilesEvent) async {
        do {
            try await withMutation { strategy in
                await strategy.performSourceEvent(event)
            }
        } catch is CancellationError {
            pp_log(ctx, .os, .debug, "Cancelled source event")
        } catch {
            pp_log(ctx, .os, .error, "Unable to process source event: \(error)")
        }
    }

    func performSourceEvent(_ event: ProfilesEvent) async {
        switch event {
        case .snapshot(let profiles):
            await performSourceSnapshot(profiles)
        case .changes(let changes):
            for change in changes {
                await performSourceChange(change)
            }
        }
    }

    func performSourceSnapshot(_ profiles: [Profile]) async {
        pp_log(ctx, .os, .debug, "Reconcile source snapshot: \(profiles.map(\.id))")
        var managers: [Profile.ID: NETunnelProviderManager]
        do {
            managers = try await reloadAllManagers()
        } catch {
            pp_log(ctx, .os, .fault, "Unable to reload managers: \(error)")
            return
        }

        // Remove managers that are no longer backed by the source.
        let profileIds = Set(profiles.map(\.id))
        managers = managers.filter {
            let profileId = $0.key
            guard profileIds.contains(profileId) else {
                pp_log(ctx, .os, .debug, "Ignore manager (unowned id: \(profileId))")
                return false
            }
            return true
        }

        // Publish retained managers before saving so updates reuse them.
        allManagers = managers

        pp_log(ctx, .os, .info, "Saving \(profiles.count) profiles...")
        let startDate = Date()
        var actuallySaved = 0
        for profile in profiles {
            // If the profile is associated with a manager, ensure that
            // it truly requires an update by comparing fingerprints.
            if let manager = managers[profile.id], let fp = manager.fingerprint {
                guard fp != fingerprint(profile) else {
                    pp_log(ctx, .os, .debug, "Manager \(profile.id) is up-to-date (fingerprint matches)")
                    actuallySaved += 1
                    continue
                }
            }
            pp_log(ctx, .os, .info, "Manager \(profile.id) requires update (fingerprint differs)")
            do {
                try await performSave(profile, forConnecting: false, options: [:])
                actuallySaved += 1
            } catch {
                pp_log(ctx, .os, .error, "Unable to save profile \(profile.id): \(error)")
            }
        }
        let elapsed = -startDate.timeIntervalSinceNow
        pp_log(ctx, .os, .info, "Saved \(actuallySaved)/\(profiles.count) profiles in: \(elapsed)")
    }

    func performSourceChange(_ change: ProfilesEvent.Change) async {
        switch change {
        case .upsert(let profile):
            pp_log(ctx, .os, .info, "Source upsert: \(profile.id)")
            do {
                try await performSave(
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
                try await performRemove(profileId: profileId)
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
        let snapshot = NETunnelManagerSnapshot(manager: manager, profileId: profileId)
        Task { [weak self] in
            await self?.updateCurrentManagersIfNeeded(with: manager, snapshot: snapshot)
        }
    }
}

// MARK: - Concurrency

private extension NETunnelStrategy {
    func withMutation<T: Sendable>(
        _ operation: @escaping @Sendable (isolated NETunnelStrategy) async throws -> T
    ) async throws -> T {
        let task = mutationTask(operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func mutationTask<T: Sendable>(
        _ operation: @escaping @Sendable (isolated NETunnelStrategy) async throws -> T
    ) -> Task<T, Error> {
        let previousTask = mutationTail
        let task = Task { [weak self] in
            await previousTask?.value
            try Task.checkCancellation()
            guard let self else {
                throw CancellationError()
            }
            return try await operation(self)
        }
        mutationTail = Task {
            _ = try? await task.value
        }
        return task
    }

    func saveManager(
        _ profileId: Profile.ID,
        block: @escaping @Sendable (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        try await saveManager(allManagers[profileId] ?? NETunnelProviderManager(), block: block)
    }

    @discardableResult
    func saveManager(
        _ manager: NETunnelProviderManager,
        block: @escaping @Sendable (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        try await preferences.load(manager)
        try Task.checkCancellation()
        block(manager)
        try Task.checkCancellation()
        try await preferences.save(manager)
        return manager
    }

    func performDisconnect(from profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await saveManager(manager) {
            $0.isOnDemandEnabled = false
        }
        // XXX: Mitigate races where the on-demand flag, despite saveToPreferences(),
        // is not disabled yet, thus causing the tunnel to reconnect.
        try await Task.sleep(for: .milliseconds(200))
        manager.connection.stopVPNTunnel()
        await manager.connection.waitForDisconnection()
    }

    func disconnectCurrentManagers() async {
        let profileIds = allManagers.compactMap { profileId, manager in
            let status = manager.connection.status.asTunnelStatus
            return status != .inactive || manager.isOnDemandEnabled ? profileId : nil
        }
        for profileId in profileIds {
            pp_log(ctx, .os, .notice, "Disconnect from \(profileId)...")
            do {
                try await performDisconnect(from: profileId)
            } catch {
                pp_log(ctx, .os, .error, "Unable to disconnect from \(profileId): \(error)")
            }
            pp_log(ctx, .os, .notice, "Disconnection of \(profileId) complete!")
        }
    }
}

private struct SendableTunnelOptions: @unchecked Sendable {
    let value: [String: NSObject]?

    init(_ value: [String: NSObject]?) {
        self.value = value
    }
}

private struct SendableProviderSession: @unchecked Sendable {
    let value: NETunnelProviderSession?

    init(_ value: NETunnelProviderSession?) {
        self.value = value
    }
}

// MARK: - Active managers

private extension NETunnelStrategy {
    nonisolated var activeProfilesStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        let stream = managerSnapshotsSubject.subscribe()
        let mappedStream: AsyncStream<[Profile.ID: TunnelSnapshot]>

//        if options.contains(.multiple) {
//            mappedStream = stream
//                .map {
//                    // Active managers are those ranked > 0
//                    $0.filter {
//                        $0.value.rank > 0
//                    }
//                    .mapValues(\.snapshot)
//                }
//        } else {
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
                    return filtered.mapValues(\.snapshot)
                }
//        }

        return mappedStream.removeDuplicates()
    }

    func publishManagerSnapshots(overriding override: NETunnelManagerSnapshot? = nil) {
        var snapshots = allManagers.compactMapValues(\.managerSnapshot)
        if let override {
            snapshots[override.snapshot.id] = override
        }
        managerSnapshotsSubject.send(snapshots)
    }

    func reloadAllManagers() async throws -> [Profile.ID: NETunnelProviderManager] {
        let loadedManagers = try await preferences.loadAll()
        pp_log(ctx, .os, .debug, "All managers (\(loadedManagers.count)): \(loadedManagers.compactMap(\.localizedDescription))")
        var managers: [Profile.ID: NETunnelProviderManager] = [:]
        for manager in loadedManagers {
            guard manager.tunnelBundleIdentifier == bundleIdentifier else {
                pp_log(ctx, .os, .debug, "Ignore manager (different bundle: \(manager.tunnelBundleIdentifier.debugDescription))")
                continue
            }
            guard let proto = manager.tunnelProtocol else {
                pp_log(ctx, .os, .debug, "Ignore manager (wrong protocol type)")
                continue
            }
            guard let profileId = proto.profileId else {
                pp_log(ctx, .os, .debug, "Discard manager (missing id)")
                manager.removeFromPreferences(completionHandler: nil)
                continue
            }
            guard coder.owns(proto, for: profileId) else {
                pp_log(ctx, .os, .debug, "Ignore manager (different owner)")
                continue
            }
            managers[profileId] = manager
        }
        logManagers(managers)
        return managers
    }

    func updateCurrentManagersIfNeeded(
        with manager: NETunnelProviderManager,
        snapshot: NETunnelManagerSnapshot
    ) {
        let profileId = snapshot.snapshot.id

        // IMPORTANT: It must be a tracked manager. We might receive notifications
        // from a manager with the same profile ID but owned by a different user.
        guard manager === allManagers[profileId] else { return }

        if snapshot.isInvalid {
            allManagers.removeValue(forKey: profileId)
        } else {
            publishManagerSnapshots(overriding: snapshot)
        }
    }

    func logManagers(_ managers: [Profile.ID: NETunnelProviderManager]) {
        if !managers.isEmpty {
            pp_log(ctx, .os, .debug, "NETunnelStrategy.allManagers:")
        } else {
            pp_log(ctx, .os, .debug, "NETunnelStrategy.allManagers: none")
        }
        managers.values.forEach {
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

struct NETunnelManagerSnapshot: Sendable {
    let status: NEVPNStatus
    let rank: Int
    let isInvalid: Bool
    let snapshot: TunnelSnapshot

    init(manager: NETunnelProviderManager, profileId: Profile.ID) {
        self.init(
            status: manager.connection.status,
            isEnabled: manager.isEnabled,
            isOnDemandEnabled: manager.isOnDemandEnabled,
            rank: manager.rank,
            profileId: profileId
        )
    }

    init(
        status: NEVPNStatus,
        isEnabled: Bool,
        isOnDemandEnabled: Bool,
        rank: Int,
        profileId: Profile.ID
    ) {
        self.status = status
        self.rank = rank
        isInvalid = status == .invalid

        let tunnelStatus = status.asTunnelStatus
        let isEnabled = isEnabled && (isOnDemandEnabled || tunnelStatus != .inactive)
        snapshot = TunnelSnapshot(
            id: profileId,
            isEnabled: isEnabled,
            status: tunnelStatus,
            onDemand: isEnabled && isOnDemandEnabled
        )
    }
}

private extension NETunnelProviderManager {
    var managerSnapshot: NETunnelManagerSnapshot? {
        guard let profileId else { return nil }
        return NETunnelManagerSnapshot(manager: self, profileId: profileId)
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
