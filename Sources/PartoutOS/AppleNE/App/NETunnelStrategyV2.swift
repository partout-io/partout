// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension

/// A tunnel strategy based on `NETunnelProviderManager`.
public actor NETunnelStrategyV2 {
    public enum Option: Sendable {
        case multiple
    }

    private let ctx: PartoutLoggerContext

    private let bundleIdentifier: String

    private let coder: NEProtocolCoder

    private let store: NETunnelManagerStore

    private let options: Set<Option>

    private let title: @Sendable (Profile) -> String

    private nonisolated let managersSubject: CurrentValueStream<[Profile.ID: NETunnelProviderManager]>

    private var allManagers: [Profile.ID: NETunnelProviderManager] {
        didSet {
            managersSubject.send(allManagers)
        }
    }

    private var lastManagerMutation: Task<Void, Error>?

    private var pendingReload: (
        task: Task<[NETunnelProviderManager], Error>,
        recoversProfiles: Bool
    )?

    private var shouldReloadAgain = false

    // TODO: #218/passepartout, support .multiple option after implementing in PTP
    public init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        coder: NEProtocolCoder,
//        options: Set<Option> = []
        title: @escaping @Sendable (Profile) -> String
    ) {
        self.init(
            ctx,
            bundleIdentifier: bundleIdentifier,
            coder: coder,
            store: SystemNETunnelManagerStore(),
            title: title
        )
    }

    init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        coder: NEProtocolCoder,
        store: NETunnelManagerStore,
        title: @escaping @Sendable (Profile) -> String
    ) {
        self.ctx = ctx
        self.bundleIdentifier = bundleIdentifier
        self.coder = coder
        self.store = store
//        self.options = options
        self.title = title
        options = []
        managersSubject = CurrentValueStream([:])
        allManagers = [:]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNConfigurationChange),
            name: .NEVPNConfigurationChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNStatus),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - TunnelObservableStrategy

extension NETunnelStrategyV2: TunnelObservableStrategy {
    public func prepare(purge: Bool) async throws {
        _ = try await reloadManagers(recoverProfiles: purge)
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
        await waitForPendingReload()
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
                        pp_log(ctx, .os, .debug, "Cancelled NETunnelStrategyV2.didUpdateActiveProfiles")
                        break
                    }
                    pp_log(ctx, .os, .debug, "NETunnelStrategyV2.activeProfiles -> \(activeProfiles.values.description)")
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

// MARK: - NETunnelManagerRepository

extension NETunnelStrategyV2: NETunnelManagerRepository {
    public func fetch() async throws -> [NETunnelProviderManager] {
        try await reloadManagers(recoverProfiles: true)
    }

    public func save<O>(_ profile: Profile, forConnecting: Bool, options: O?) async throws {
        await waitForPendingReload()
        let existingManager = allManagers[profile.id]
        let manager: NETunnelProviderManager
        do {
            manager = try await saveProfile(
                profile,
                manager: existingManager,
                forConnecting: forConnecting,
                options: options
            )
        } catch {
            // A regular save creates the keychain entry first. Roll it back if
            // the corresponding manager could not be created.
            if existingManager == nil {
                try? coder.removeProfile(withId: profile.id)
            }
            throw error
        }
        allManagers[profile.id] = manager
    }

    public func remove(profileId: Profile.ID) async throws {
        await waitForPendingReload()
        guard let manager = allManagers[profileId] else {
            return
        }
        let store = store
        try await mutatePreferences {
            try await store.remove(manager)
        }
        allManagers.removeValue(forKey: profileId)
        try? coder.removeProfile(withId: profileId)
    }

    public nonisolated func profile(from manager: NETunnelProviderManager) throws -> Profile {
        guard let proto = manager.tunnelProtocol else {
            throw PartoutError(.decoding)
        }
        return try coder.profile(from: proto)
    }

    public nonisolated var managersStream: AsyncStream<[Profile.ID: NETunnelProviderManager]> {
        let stream = managersSubject.subscribe().dropFirst()
        return AsyncStream { [weak self] continuation in
            let task = Task { [weak self] in
                for await value in stream {
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .os, .debug, "Cancelled NETunnelStrategyV2.managersStream")
                        break
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private extension NETunnelStrategyV2 {
    @discardableResult
    func saveProfile<O>(
        _ profile: Profile,
        manager existingManager: NETunnelProviderManager?,
        forConnecting: Bool,
        options: O?
    ) async throws -> NETunnelProviderManager {
        profile.log(.os, .notice, withPreamble: "Encoded profile:")

        let proto = try coder.protocolConfiguration(from: profile, title: title)

        // store custom data on the side
        proto.profileId = profile.id

        let manager = try await saveAtomically(existingManager ?? NETunnelProviderManager()) {
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

            // do not alter these two flags unless connecting explicitly
            $0.isEnabled = forConnecting || $0.isEnabled
            $0.isOnDemandEnabled = (forConnecting || $0.isOnDemandEnabled) && shouldEnableOnDemand
        }

        if forConnecting {
            let options = options as? [String: NSObject]
            try manager.connection.startVPNTunnel(options: options)
        }
        return manager
    }
}

// MARK: - Notifications

private extension NETunnelStrategyV2 {

    @objc
    nonisolated func onVPNConfigurationChange(_ notification: Notification) {
        if let manager = notification.object as? NETunnelProviderManager,
           let managerBundleIdentifier = manager.tunnelBundleIdentifier,
           managerBundleIdentifier != bundleIdentifier {
            return
        }

        let profileId = (notification.object as? NETunnelProviderManager)?.tunnelProtocol?.profileId
        pp_log(ctx, .os, .debug, "NEVPNConfigurationChange(\(profileId?.description ?? "unknown")): \(notification)")
        Task {
            await reloadAfterConfigurationChange()
        }
    }

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

private extension NETunnelStrategyV2 {
    @discardableResult
    func saveAtomically(
        _ managerBlock: @escaping @autoclosure () -> NETunnelProviderManager,
        block: @escaping @Sendable (NETunnelProviderManager) -> Void
    ) async throws -> NETunnelProviderManager {
        let manager = managerBlock()
        let store = store
        try await mutatePreferences {
            try await store.load(manager)
            try Task.checkCancellation()
            block(manager)
            try Task.checkCancellation()
            try await store.save(manager)
        }
        return manager
    }

    func mutatePreferences(
        _ block: @escaping @Sendable () async throws -> Void
    ) async throws {
        let previousMutation = lastManagerMutation
        let mutation = Task {
            // The previous caller already receives its own error. A failed write
            // must not prevent later writes from being attempted.
            _ = try? await previousMutation?.value
            try Task.checkCancellation()
            try await block()
        }
        lastManagerMutation = mutation
        try await mutation.value
    }

    func waitForManagerMutation() async {
        _ = try? await lastManagerMutation?.value
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

// MARK: - Active managers

private extension NETunnelStrategyV2 {
    nonisolated var activeProfilesStream: AsyncStream<[Profile.ID: TunnelSnapshot]> {
        let stream = managersSubject.subscribe()
        let mappedStream: AsyncStream<[Profile.ID: TunnelSnapshot]>

        if options.contains(.multiple) {
            mappedStream = stream
                .map {
                    // active managers are those ranked > 0
                    $0.filter {
                        $0.value.rank > 0
                    }
                    .compactMapValues(\.asSnapshot)
                }
        } else {
            mappedStream = stream
                .map {
                    // active manager is the max ranked
                    let maxRank = $0.max {
                        $0.value.rank < $1.value.rank
                    }?.value.rank ?? 0

                    // if max rank is 0, no manager is active
                    guard maxRank > 0 else {
                        return [:]
                    }

                    // return the max ranked manager
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

    func reloadManagers(recoverProfiles: Bool) async throws -> [NETunnelProviderManager] {
        if let pendingReload {
            let managers = try await pendingReload.task.value
            if recoverProfiles && !pendingReload.recoversProfiles {
                return try await reloadManagers(recoverProfiles: true)
            }
            return managers
        }

        let task = Task {
            try await reloadManagersUntilCurrent(recoverProfiles: recoverProfiles)
        }
        pendingReload = (task, recoverProfiles)
        return try await task.value
    }

    func reloadManagersUntilCurrent(
        recoverProfiles: Bool
    ) async throws -> [NETunnelProviderManager] {
        defer {
            pendingReload = nil
        }

        var recoverProfiles = recoverProfiles
        var managers: [Profile.ID: NETunnelProviderManager] = [:]
        repeat {
            shouldReloadAgain = false
            managers = try await loadManagers(recoverProfiles: recoverProfiles)
            recoverProfiles = false

            if shouldReloadAgain {
                pp_log(ctx, .os, .debug, "Reload managers again after configuration changes")
            }
        } while shouldReloadAgain

        allManagers = managers
        logManagers()
        return Array(managers.values)
    }

    func loadManagers(
        recoverProfiles: Bool
    ) async throws -> [Profile.ID: NETunnelProviderManager] {
        await waitForManagerMutation()

        var managers = try await loadManagedManagers(removeInvalidProfiles: recoverProfiles)
        guard recoverProfiles else {
            return managers
        }

        let profiles = await coder.recoverProfiles(notReferencedBy: Array(managers.values))
        for profile in profiles where managers[profile.id] == nil {
            do {
                pp_log(ctx, .os, .notice, "Restore stale profile: \(profile.id)")
                managers[profile.id] = try await saveProfile(
                    profile,
                    manager: nil,
                    forConnecting: false,
                    options: nil as Void?
                )
            } catch {
                // This is a recovery, so keep the keychain profile for the next attempt.
                pp_log(ctx, .os, .error, "Unable to restore stale profile \(profile.id): \(error)")
            }
        }

        // Preference writes emit configuration notifications. Verify what the
        // system persisted before publishing the new state.
        return try await loadManagedManagers(removeInvalidProfiles: true)
    }

    func loadManagedManagers(
        removeInvalidProfiles: Bool
    ) async throws -> [Profile.ID: NETunnelProviderManager] {
        let loadedManagers = try await store.loadAll()
        var managers: [Profile.ID: NETunnelProviderManager] = [:]

        for manager in loadedManagers {
            guard manager.tunnelBundleIdentifier == bundleIdentifier else {
                await removeManager(manager, reason: "unexpected tunnel bundle identifier")
                continue
            }
            guard let profileId = manager.tunnelProtocol?.profileId else {
                await removeManager(manager, reason: "missing profile identifier")
                continue
            }
            if removeInvalidProfiles {
                do {
                    _ = try coder.profile(from: manager.tunnelProtocol!)
                } catch {
                    await removeManager(manager, reason: "unable to decode profile: \(error)")
                    continue
                }
            }
            guard let existingManager = managers[profileId] else {
                managers[profileId] = manager
                continue
            }

            let managerToKeep: NETunnelProviderManager
            let duplicateManager: NETunnelProviderManager
            if manager.rank > existingManager.rank {
                managerToKeep = manager
                duplicateManager = existingManager
            } else {
                managerToKeep = existingManager
                duplicateManager = manager
            }
            managers[profileId] = managerToKeep
            await removeManager(duplicateManager, reason: "duplicate for profile \(profileId)")
        }
        return managers
    }

    func removeManager(
        _ manager: NETunnelProviderManager,
        reason: String
    ) async {
        pp_log(ctx, .os, .error, "Remove NE manager '\(manager.localizedDescription ?? "")': \(reason)")
        do {
            try await store.remove(manager)
        } catch {
            pp_log(ctx, .os, .error, "Unable to remove NE manager '\(manager.localizedDescription ?? "")': \(error)")
        }
    }

    func waitForPendingReload() async {
        while let pendingReload {
            do {
                _ = try await pendingReload.task.value
            } catch {
                pp_log(ctx, .os, .error, "Pending manager reload failed: \(error)")
            }
        }
    }

    func reloadAfterConfigurationChange() async {
        guard pendingReload == nil else {
            shouldReloadAgain = true
            return
        }
        do {
            _ = try await reloadManagers(recoverProfiles: false)
        } catch {
            pp_log(ctx, .os, .error, "Unable to reload managers: \(error)")
        }
    }

    func updateCurrentManagersIfNeeded(with manager: NETunnelProviderManager, profileId: Profile.ID) {

        // deletion
        if allManagers.keys.contains(profileId), manager.connection.status == .invalid {
            allManagers.removeValue(forKey: profileId)
        }
        // update
        else {
            allManagers[profileId] = manager
        }
    }

    func logManagers() {
        if !allManagers.isEmpty {
            pp_log(ctx, .os, .debug, "NETunnelStrategyV2.allManagers:")
        } else {
            pp_log(ctx, .os, .debug, "NETunnelStrategyV2.allManagers: none")
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
        // only one profile at a time is enabled on iOS/tvOS
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

// MARK: - Profile ID

private enum CustomProviderKey: String {
    case profileId

    var key: String {
        "CustomProviderKey.\(rawValue)"
    }
}

private extension NETunnelProviderManager {
    var profileId: Profile.ID? {
        tunnelProtocol?.profileId
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

protocol NETunnelManagerStore: Sendable {
    func loadAll() async throws -> [NETunnelProviderManager]
    func load(_ manager: NETunnelProviderManager) async throws
    func save(_ manager: NETunnelProviderManager) async throws
    func remove(_ manager: NETunnelProviderManager) async throws
}

private struct SystemNETunnelManagerStore: NETunnelManagerStore {
    func loadAll() async throws -> [NETunnelProviderManager] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }

    func load(_ manager: NETunnelProviderManager) async throws {
        try await manager.loadFromPreferences()
    }

    func save(_ manager: NETunnelProviderManager) async throws {
        try await manager.saveToPreferences()
    }

    func remove(_ manager: NETunnelProviderManager) async throws {
        try await manager.removeFromPreferences()
    }
}
