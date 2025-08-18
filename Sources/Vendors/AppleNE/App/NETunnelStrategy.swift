// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
@preconcurrency import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// Implementation of ``/PartoutCore/TunnelStrategy`` based on `NETunnelProviderManager`.
public actor NETunnelStrategy {
    public enum Option: Sendable {
        case multiple
    }

    private let ctx: PartoutLoggerContext

    private let bundleIdentifier: String

    private let coder: NEProtocolCoder

    private let options: Set<Option>

    private nonisolated let managersSubject: CurrentValueStream<[Profile.ID: NETunnelProviderManager]>

    private var allManagers: [Profile.ID: NETunnelProviderManager] {
        didSet {
            managersSubject.send(allManagers)
        }
    }

    private var pendingSaveTask: Task<Void, Error>?

    // TODO: #218/passepartout, support .multiple option after implementing in PTP
    public init(
        _ ctx: PartoutLoggerContext,
        bundleIdentifier: String,
        coder: NEProtocolCoder,
//        options: Set<Option> = []
    ) {
        self.ctx = ctx
        self.bundleIdentifier = bundleIdentifier
        self.coder = coder
//        self.options = options
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

extension NETunnelStrategy: TunnelObservableStrategy {
    public func prepare(purge: Bool) async throws {
        try await reloadAllManagers()
        if purge {
            await coder.purge(managers: Array(allManagers.values))
        }
    }

    public func install(
        _ profile: Profile,
        connect: Bool,
        options: Sendable?,
        title: @escaping @Sendable (Profile) -> String
    ) async throws {
        if connect, !self.options.contains(.multiple) {
            await disconnectCurrentManagers()
        }
        let nsOptions = options as? [String: NSObject]
        try await save(profile, forConnecting: connect, options: nsOptions, title: title)
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

    public nonisolated var didUpdateActiveProfiles: AsyncStream<[Profile.ID: TunnelActiveProfile]> {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await activeProfiles in self.activeProfilesStream.dropFirst() {
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .ne, .debug, "Cancelled NETunnelStrategy.didUpdateActiveProfiles")
                        break
                    }
                    pp_log(self.ctx, .ne, .debug, "NETunnelStrategy.activeProfiles -> \(activeProfiles.values.description)")
                    continuation.yield(activeProfiles)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - NETunnelManagerRepository

extension NETunnelStrategy: NETunnelManagerRepository {
    public func fetch() async throws -> [NETunnelProviderManager] {
        try await reloadAllManagers()
        let managers = Array(allManagers.values)
        await coder.purge(managers: managers)
        return managers
    }

    public func save<O>(
        _ profile: Profile,
        forConnecting: Bool,
        options: O?,
        title: @Sendable (Profile) -> String
    ) async throws {
        profile.log(.ne, .notice, withPreamble: "Encoded profile:")

        let proto = try coder.protocolConfiguration(
            from: profile,
            title: title
        )

        // store custom data on the side
        proto.profileId = profile.id

        let manager: NETunnelProviderManager
        do {
            manager = try await saveAtomically(profile.id) {
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
        } catch {

            // revert adds, retain updates
            if allManagers[profile.id] == nil {
                try? coder.removeProfile(withId: profile.id)
            }

            throw error
        }

        if forConnecting {
            let options = options as? [String: NSObject]
            try manager.connection.startVPNTunnel(options: options)
        }
    }

    public func remove(profileId: Profile.ID) async throws {
        guard let manager = allManagers[profileId] else {
            return
        }
        try await manager.removeFromPreferences()
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
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                for await value in self.managersSubject.subscribe().dropFirst() {
                    guard !Task.isCancelled else {
                        pp_log(self.ctx, .ne, .debug, "Cancelled NETunnelStrategy.managersStream")
                        break
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Notifications

private extension NETunnelStrategy {

    @objc
    nonisolated func onVPNConfigurationChange(_ notification: Notification) {
        guard let manager = notification.object as? NETunnelProviderManager,
              manager.tunnelBundleIdentifier == bundleIdentifier,
              let profileId = manager.tunnelProtocol?.profileId else {
            return
        }

        pp_log(ctx, .ne, .debug, "NEVPNConfigurationChange(\(profileId)): \(notification)")
        Task {
            do {
                try await reloadAllManagers()
            } catch {
                pp_log(ctx, .ne, .error, "Unable to reload managers: \(error)")
            }
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

//        pp_log(ctx, .ne, .debug, "NEVPNStatusDidChange: \(notification)")
        pp_log(ctx, .ne, .debug, "NEVPNStatus(\(profileId)) -> \(connection.status.rawValue)")
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
        if let pendingSaveTask {
            try await pendingSaveTask.value
        }
        let manager = managerBlock()
        pendingSaveTask = Task { @Sendable in
            try await manager.loadFromPreferences()
            try Task.checkCancellation()
            block(manager)
            try Task.checkCancellation()
            try await manager.saveToPreferences()
        }
        try await pendingSaveTask?.value
        pendingSaveTask = nil
        return manager
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
                    pp_log(ctx, .ne, .notice, "Disconnect from \(pair.key)...")
                    do {
                        try await disconnect(from: pair.key)
                    } catch {
                        pp_log(ctx, .ne, .error, "Unable to disconnect from \(pair.key): \(error)")
                    }
                    pp_log(ctx, .ne, .notice, "Disconnection of \(pair.key) complete!")
                }
            }
        }
    }
}

// MARK: - Active managers

private extension NETunnelStrategy {
    nonisolated var activeProfilesStream: AsyncStream<[Profile.ID: TunnelActiveProfile]> {
        let stream = managersSubject.subscribe()
        let mappedStream: AsyncStream<[Profile.ID: TunnelActiveProfile]>

        if options.contains(.multiple) {
            mappedStream = stream
                .map {
                    // active managers are those ranked > 0
                    $0.filter {
                        $0.value.rank > 0
                    }
                    .compactMapValues(\.asActiveProfile)
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
                    assert(filtered.count <= 1, "Max ranked manager must be at most one")
                    return filtered.compactMapValues(\.asActiveProfile)
                }
        }

        return mappedStream.removeDuplicates()
    }

    func reloadAllManagers() async throws {
        var removedManagers = allManagers

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        allManagers = managers.reduce(into: [:]) {
            guard $1.tunnelBundleIdentifier == bundleIdentifier else {
                $1.removeFromPreferences()
                return
            }
            guard let profileId = $1.tunnelProtocol?.profileId else {
                $1.removeFromPreferences()
                return
            }
            $0[profileId] = $1
            removedManagers.removeValue(forKey: profileId)
        }

        // clean up coder data of removed managers
        removedManagers.forEach {
            try? coder.removeProfile(withId: $0.key)
        }

        logManagers()
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
            pp_log(ctx, .ne, .debug, "NETunnelStrategy.allManagers:")
        } else {
            pp_log(ctx, .ne, .debug, "NETunnelStrategy.allManagers: none")
        }
        allManagers.values.forEach {
            guard let profileId = $0.tunnelProtocol?.profileId else {
                return
            }
            pp_log(ctx, .ne, .debug, "\t\($0.localizedDescription ?? "")(\(profileId)): isEnabled=\($0.isEnabled), isOnDemandEnabled=\($0.isOnDemandEnabled), status=\($0.connection.status), rank=\($0.rank)")
        }
    }
}

private extension NETunnelProviderManager {
    var rank: Int {
#if os(iOS) || os(tvOS)
        // only one profile at a time is enabled on iOS/tvOS
        if isEnabled {
            return .max
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
    var profileId: UUID? {
        get {
            guard let uuidString = providerConfiguration?[CustomProviderKey.profileId.key] as? String else {
                return nil
            }
            return UUID(uuidString: uuidString)
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

extension NETunnelProviderManager: @retroactive @unchecked Sendable {
}

private extension NETunnelProviderManager {
    var asActiveProfile: TunnelActiveProfile? {
        guard let profileId else {
            return nil
        }
        return TunnelActiveProfile(
            id: profileId,
            status: connection.status.asTunnelStatus,
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
