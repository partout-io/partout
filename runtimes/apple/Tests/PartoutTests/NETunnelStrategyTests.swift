// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(NetworkExtension)

import Foundation
@preconcurrency import NetworkExtension
@testable import PartoutCore
import Testing

struct NETunnelStrategyContractTests {
    @Test
    func saveConfiguresAndPersistsManager() async throws {
        let store = MockTunnelPreferences(isEnabledOnLoad: false)
        let profile = try Profile.Builder(name: "My profile").build()
        let strategy = makeStrategy(preferences: store.preferences)

        try await strategy.install(profile, connect: false, options: nil)

        let actions = await store.actions
        let manager = try #require(await store.savedManagers.first)
        let proto = try #require(manager.protocolConfiguration as? NETunnelProviderProtocol)
        #expect(actions == [.load(nil), .save(profile.id)])
        #expect(manager.localizedDescription == profile.name)
        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.profileId == profile.id)
        #expect(!manager.isEnabled)
        #expect(!manager.isOnDemandEnabled)
    }

    @Test
    func saveEnablesOnDemandForRunningManager() async throws {
        for status in [NEVPNStatus.connecting, .connected, .reasserting] {
            let profile = try makeOnDemandProfile(isActive: true)
            let store = MockTunnelPreferences(
                managers: [makeManager(
                    profileId: profile.id,
                    fingerprint: profile.name,
                    status: status
                )]
            )
            let strategy = try await makePreparedStrategy(profile: profile, store: store)

            try await strategy.save(profile, forConnecting: false, options: nil)

            let manager = try #require(await store.savedManagers.last)
            #expect(manager.isOnDemandEnabled, "status: \(status.rawValue)")
        }
    }

    @Test
    func saveDoesNotEnableOnDemandForNonRunningManager() async throws {
        for status in [NEVPNStatus.invalid, .disconnected, .disconnecting] {
            let profile = try makeOnDemandProfile(isActive: true)
            let store = MockTunnelPreferences(
                managers: [makeManager(
                    profileId: profile.id,
                    fingerprint: profile.name,
                    status: status
                )]
            )
            let strategy = try await makePreparedStrategy(profile: profile, store: store)

            try await strategy.save(profile, forConnecting: false, options: nil)

            let manager = try #require(await store.savedManagers.last)
            #expect(!manager.isOnDemandEnabled, "status: \(status.rawValue)")
        }
    }

    @Test
    func savePreservesOnDemandForDisconnectedManager() async throws {
        let profile = try makeOnDemandProfile(isActive: true)
        let store = MockTunnelPreferences(
            managers: [makeManager(
                profileId: profile.id,
                fingerprint: profile.name,
                status: .disconnected,
                isOnDemandEnabled: true
            )]
        )
        let strategy = try await makePreparedStrategy(profile: profile, store: store)

        try await strategy.save(profile, forConnecting: false, options: nil)

        let manager = try #require(await store.savedManagers.last)
        #expect(manager.isOnDemandEnabled)
    }

    @Test
    func saveDisablesOnDemandForRunningManager() async throws {
        let profile = try makeOnDemandProfile(isActive: false)
        let store = MockTunnelPreferences(
            managers: [makeManager(
                profileId: profile.id,
                fingerprint: profile.name,
                status: .connected,
                isOnDemandEnabled: true
            )]
        )
        let strategy = try await makePreparedStrategy(profile: profile, store: store)

        try await strategy.save(profile, forConnecting: false, options: nil)

        let manager = try #require(await store.savedManagers.last)
        #expect(!manager.isOnDemandEnabled)
    }

    @Test
    func unknownProfileOperationsAreNoOps() async throws {
        let store = MockTunnelPreferences()
        let strategy = makeStrategy(preferences: store.preferences)
        let profileId = Profile.ID()

        try await strategy.uninstall(profileId: profileId)
        try await strategy.disconnect(from: profileId)
        let response = try await strategy.sendMessage(Data(), to: profileId)

        #expect(response == nil)
        #expect(await store.actions.isEmpty)
    }

    @Test
    func activeProfilesStartsEmpty() async throws {
        let strategy = makeStrategy(preferences: MockTunnelPreferences().preferences)
        var iterator = strategy.didUpdateActiveProfiles.makeAsyncIterator()

        #expect(await iterator.next()?.isEmpty == true)
    }

    @Test
    func preparedManagerIsPublishedAndCanBeUninstalled() async throws {
        let profile = try Profile.Builder(name: "loaded").build()
        let store = MockTunnelPreferences(
            managers: [makeManager(profileId: profile.id, fingerprint: profile.name)]
        )
        let strategy = try await makePreparedStrategy(
            profile: profile,
            store: store
        )

        try await strategy.uninstall(profileId: profile.id)

        #expect(await store.actions == [.loadAll, .remove(profile.id)])
    }
}

struct NETunnelStrategySnapshotTests {
    @Test
    func snapshotReconcilesStaleAndChangedManagersAndContinuesAfterFailures() async throws {
        let matching = try Profile.Builder(name: "matching").build()
        let changed = try Profile.Builder(name: "changed").build()
        let missingFingerprint = try Profile.Builder(name: "missing-fingerprint").build()
        let new = try Profile.Builder(name: "new").build()
        let stale = Profile.ID()
        let staleWithFailedRemoval = Profile.ID()

        let store = MockTunnelPreferences(
            managers: [
                makeManager(profileId: matching.id, fingerprint: matching.name),
                makeManager(profileId: changed.id, fingerprint: "old"),
                makeManager(profileId: missingFingerprint.id, fingerprint: nil),
                makeManager(profileId: stale, fingerprint: "stale"),
                makeManager(profileId: staleWithFailedRemoval, fingerprint: "stale-failure")
            ],
            saveFailures: [changed.id],
            removeFailures: [staleWithFailedRemoval]
        )
        let (source, continuation) = AsyncStream.makeStream(of: ProfilesEvent.self)
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: bundleIdentifier,
            source: source,
            coder: protocolCoder,
            preferences: store.preferences,
            fingerprint: {
                $0.id == missingFingerprint.id ? nil : $0.name
            }
        )

        try await strategy.prepare(purge: false)
        try await strategy.prepare(purge: false)
        continuation.yield(.snapshot([matching, changed, missingFingerprint, new]))
        await store.waitForActionCount(7)

        try await strategy.uninstall(profileId: staleWithFailedRemoval)
        try await strategy.uninstall(profileId: matching.id)
        continuation.finish()

        let actions = await store.actions
        let savedIds = actions.compactMap(\.savedProfileId)
        let removedIds = actions.compactMap(\.removedProfileId)
        #expect(actions.filter(\.isLoadAll).count == 1)
        #expect(Set(savedIds) == [changed.id, missingFingerprint.id, new.id])
        #expect(!savedIds.contains(matching.id))
        #expect(!removedIds.contains(stale))
        #expect(!removedIds.contains(staleWithFailedRemoval))
        #expect(removedIds.filter { $0 == matching.id }.count == 1)
    }

    @Test
    func slowSnapshotDelaysFollowingSaveWithoutInterleaving() async throws {
        let snapshotProfile = try Profile.Builder(name: "snapshot").build()
        let explicitProfile = try Profile.Builder(name: "explicit").build()
        let loadAllGate = PreferenceGate()
        let store = MockTunnelPreferences(loadAllGate: loadAllGate)
        let (source, continuation) = AsyncStream.makeStream(of: ProfilesEvent.self)
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: bundleIdentifier,
            source: source,
            coder: protocolCoder,
            preferences: store.preferences,
            fingerprint: { $0.name }
        )

        try await strategy.prepare(purge: false)
        continuation.yield(.snapshot([snapshotProfile]))
        await loadAllGate.waitUntilEntered()

        let saveTask = Task {
            try await strategy.save(explicitProfile, forConnecting: false, options: nil)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(await store.actions == [.loadAll])

        await loadAllGate.open()
        try await saveTask.value
        continuation.finish()

        #expect(await store.actions == [
            .loadAll,
            .load(nil), .save(snapshotProfile.id),
            .load(nil), .save(explicitProfile.id)
        ])
    }
}

struct NETunnelStrategyStatusTests {
    @Test
    func snapshotPreservesObservedStatus() {
        let profileId = Profile.ID()
        let deactivating = NETunnelManagerSnapshot(
            status: .disconnecting,
            isEnabled: true,
            isOnDemandEnabled: false,
            rank: .max,
            profileId: profileId,
        )
        let inactive = NETunnelManagerSnapshot(
            status: .disconnected,
            isEnabled: false,
            isOnDemandEnabled: false,
            rank: .min,
            profileId: profileId
        )

        #expect(deactivating.snapshot.status == .deactivating)
        #expect(deactivating.snapshot.isEnabled)
        #expect(inactive.snapshot.status == .inactive)
        #expect(!inactive.snapshot.isEnabled)
    }
}

// MARK: - Strategy factories

private let bundleIdentifier = "com.example.MyTunnel"

private var protocolCoder: ProviderNEProtocolCoder {
    ProviderNEProtocolCoder(
        .global,
        tunnelBundleIdentifier: bundleIdentifier,
        coder: BasicProfileCoder(),
        uid: 100
    )
}

private func makeStrategy(
    preferences: NETunnelPreferences
) -> NETunnelStrategy {
    NETunnelStrategy(
        .global,
        bundleIdentifier: bundleIdentifier,
        source: AsyncStream { $0.finish() },
        coder: protocolCoder,
        preferences: preferences,
        fingerprint: { $0.name }
    )
}

private func makePreparedStrategy(
    profile: Profile,
    store: MockTunnelPreferences
) async throws -> NETunnelStrategy {
    let (source, continuation) = AsyncStream.makeStream(of: ProfilesEvent.self)
    let strategy = NETunnelStrategy(
        .global,
        bundleIdentifier: bundleIdentifier,
        source: source,
        coder: protocolCoder,
        preferences: store.preferences,
        fingerprint: { $0.name }
    )
    try await strategy.prepare(purge: false)
    continuation.yield(.snapshot([profile]))
    continuation.finish()
    await store.waitForActionCount(1)
    return strategy
}

private func makeOnDemandProfile(isActive: Bool) throws -> Profile {
    let onDemand = OnDemandModule.Builder().build()
    return try Profile.Builder(
        modules: [onDemand],
        activeModulesIds: isActive ? [onDemand.id] : []
    ).build()
}

// MARK: - Preferences mock

private enum PreferenceFailure: Error {
    case save
    case remove
}

private enum PreferenceAction: Equatable, Sendable {
    case loadAll
    case load(Profile.ID?)
    case save(Profile.ID?)
    case remove(Profile.ID?)

    var isLoadAll: Bool {
        guard case .loadAll = self else { return false }
        return true
    }

    var savedProfileId: Profile.ID? {
        guard case .save(let profileId) = self else { return nil }
        return profileId
    }

    var removedProfileId: Profile.ID? {
        guard case .remove(let profileId) = self else { return nil }
        return profileId
    }
}

private actor MockTunnelPreferences {
    private let managers: [NETunnelProviderManager]
    private let isEnabledOnLoad: Bool?
    private let loadAllGate: PreferenceGate?
    private let saveFailures: Set<Profile.ID>
    private let removeFailures: Set<Profile.ID>
    private var actionCountContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    private(set) var actions: [PreferenceAction] = []
    private(set) var savedManagers: [NETunnelProviderManager] = []

    init(
        managers: [NETunnelProviderManager] = [],
        isEnabledOnLoad: Bool? = nil,
        loadAllGate: PreferenceGate? = nil,
        saveFailures: Set<Profile.ID> = [],
        removeFailures: Set<Profile.ID> = []
    ) {
        self.managers = managers
        self.isEnabledOnLoad = isEnabledOnLoad
        self.loadAllGate = loadAllGate
        self.saveFailures = saveFailures
        self.removeFailures = removeFailures
    }

    nonisolated var preferences: NETunnelPreferences {
        NETunnelPreferences(
            loadAll: { [weak self] in
                guard let self else { throw CancellationError() }
                return await self.performLoadAll().value
            },
            load: { [weak self] manager in
                guard let self else { throw CancellationError() }
                await self.performLoad(manager)
            },
            save: { [weak self] manager in
                guard let self else { throw CancellationError() }
                try await self.performSave(manager)
            },
            remove: { [weak self] manager in
                guard let self else { throw CancellationError() }
                try await self.performRemove(manager)
            }
        )
    }

    func waitForActionCount(_ count: Int) async {
        guard actions.count < count else { return }
        await withCheckedContinuation {
            actionCountContinuations.append((count, $0))
        }
    }

    private func performLoadAll() async -> SendableManagers {
        record(.loadAll)
        if let loadAllGate {
            await loadAllGate.wait()
        }
        return SendableManagers(managers)
    }

    private func performLoad(_ manager: NETunnelProviderManager) {
        record(.load(manager.profileId))
        if let isEnabledOnLoad {
            manager.isEnabled = isEnabledOnLoad
        }
    }

    private func performSave(_ manager: NETunnelProviderManager) throws {
        let profileId = manager.profileId
        savedManagers.append(manager)
        record(.save(profileId))
        if let profileId, saveFailures.contains(profileId) {
            throw PreferenceFailure.save
        }
    }

    private func performRemove(_ manager: NETunnelProviderManager) throws {
        let profileId = manager.profileId
        record(.remove(profileId))
        if let profileId, removeFailures.contains(profileId) {
            throw PreferenceFailure.remove
        }
    }

    private func record(_ action: PreferenceAction) {
        actions.append(action)
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in actionCountContinuations {
            if actions.count >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        actionCountContinuations = remaining
    }
}

private struct SendableManagers: @unchecked Sendable {
    let value: [NETunnelProviderManager]

    init(_ value: [NETunnelProviderManager]) {
        self.value = value
    }
}

private actor PreferenceGate {
    private var isOpen = false
    private var isEntered = false
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        entryContinuations.forEach { $0.resume() }
        entryContinuations.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation {
            continuations.append($0)
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation {
            entryContinuations.append($0)
        }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

// MARK: - Manager metadata

private let profileIdKey = "CustomProviderKey.profileId"
private let fingerprintKey = "CustomProviderKey.fingerprint"

private func makeManager(
    profileId: Profile.ID,
    fingerprint: String?,
    status: NEVPNStatus? = nil,
    isOnDemandEnabled: Bool = false
) -> NETunnelProviderManager {
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = bundleIdentifier
    var providerConfiguration: [String: Any] = [profileIdKey: profileId.uuidString]
    providerConfiguration[fingerprintKey] = fingerprint
    proto.providerConfiguration = providerConfiguration
    let manager = status.map(TestTunnelProviderManager.init) ?? NETunnelProviderManager()
    manager.protocolConfiguration = proto
    manager.isOnDemandEnabled = isOnDemandEnabled
    return manager
}

private final class TestTunnelProviderManager: NETunnelProviderManager {
    private let testConnection: NEVPNConnection

    init(status: NEVPNStatus) {
        testConnection = TestVPNConnection(status: status)
        super.init()
    }

    override var connection: NEVPNConnection {
        testConnection
    }
}

private final class TestVPNConnection: NEVPNConnection {
    private let testStatus: NEVPNStatus

    init(status: NEVPNStatus) {
        testStatus = status
        super.init()
    }

    override var status: NEVPNStatus {
        testStatus
    }
}

private extension NETunnelProviderManager {
    var profileId: Profile.ID? {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let uuidString = proto.providerConfiguration?[profileIdKey] as? String else {
            return nil
        }
        return Profile.ID(uuidString: uuidString)
    }
}

private extension NETunnelProviderProtocol {
    var profileId: Profile.ID? {
        guard let uuidString = providerConfiguration?[profileIdKey] as? String else {
            return nil
        }
        return Profile.ID(uuidString: uuidString)
    }
}
#endif
