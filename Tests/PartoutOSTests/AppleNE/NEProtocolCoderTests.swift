// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(NetworkExtension)

import NetworkExtension
@testable import PartoutOS
import Testing

@Suite(.serialized)
struct NEProtocolCoderTests {
    let registry = Registry(withKnown: true)

    @Test
    func givenProfile_whenEncodeToProvider_thenDecodes() throws {
        let profile = try newProfile()
        let coder = CodingRegistry(registry: registry)
        let sut = ProviderNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: coder
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.providerConfiguration?[ProviderNEProtocolCoder.providerKey] as? String != nil)

        let decodedProfile = try sut.profile(from: proto)
        #expect(decodedProfile == profile)
    }

    @Test
    func givenProfile_whenEncodeToKeychain_thenDecodes() throws {
        let profile = try newProfile()
        let coder = CodingRegistry(registry: registry)
        let sut = KeychainNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: coder,
            keychain: MockKeychain()
        )

        let proto = try sut.protocolConfiguration(from: profile, title: \.name)
        #expect(proto.providerBundleIdentifier == bundleIdentifier)
        #expect(proto.providerConfiguration == nil)

        let decodedProfile = try sut.profile(from: proto)
        #expect(decodedProfile == profile)
    }

    @Test
    func givenOrphanedKeychainProfile_whenFetchTwice_thenRestoresOneManager() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        _ = try coder.protocolConfiguration(from: profile, title: \.name)
        let store = MockNETunnelManagerStore()
        let sut = newStrategy(coder: coder, store: store)

        let firstManagers = try await sut.fetch()
        let secondManagers = try await sut.fetch()
        let metrics = await store.metrics()

        #expect(firstManagers.count == 1)
        #expect(secondManagers.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.saveCount == 1)
        #expect((try? keychain.password(for: profile.id.uuidString)) != nil)
    }

    @Test
    func givenRestoreFailure_whenFetchAgain_thenRetainsAndRestoresKeychainProfile() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        _ = try coder.protocolConfiguration(from: profile, title: \.name)
        let store = MockNETunnelManagerStore(saveFailures: 1)
        let sut = newStrategy(coder: coder, store: store)

        let failedManagers = try await sut.fetch()
        #expect(failedManagers.isEmpty)
        #expect((try? keychain.password(for: profile.id.uuidString)) != nil)

        let restoredManagers = try await sut.fetch()
        let metrics = await store.metrics()

        #expect(restoredManagers.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.saveCount == 2)
    }

    @Test
    func givenConcurrentFetches_whenProfileIsOrphaned_thenSharesOneReconciliation() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        _ = try coder.protocolConfiguration(from: profile, title: \.name)
        let store = MockNETunnelManagerStore(loadDelay: .milliseconds(20))
        let sut = newStrategy(coder: coder, store: store)

        async let firstManagers = sut.fetch()
        async let secondManagers = sut.fetch()
        let results = try await (firstManagers, secondManagers)
        let metrics = await store.metrics()

        #expect(results.0.count == 1)
        #expect(results.1.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.saveCount == 1)
        #expect(metrics.loadCount == 2)
    }

    @Test
    func givenConfigurationChangeDuringFetch_whenFetchCompletes_thenPerformsFollowUpLoad() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        _ = try coder.protocolConfiguration(from: profile, title: \.name)
        let store = MockNETunnelManagerStore(loadDelay: .milliseconds(50))
        let sut = newStrategy(coder: coder, store: store)

        async let managers = sut.fetch()
        try await Task.sleep(for: .milliseconds(10))
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        let result = try await managers
        let metrics = await store.metrics()

        #expect(result.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.saveCount == 1)
        #expect(metrics.loadCount == 3)
    }

    @Test
    func givenManagerDeletedExternally_whenFetch_thenRetainsKeychainAndRestoresManager() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        _ = try coder.protocolConfiguration(from: profile, title: \.name)
        let store = MockNETunnelManagerStore()
        let sut = newStrategy(coder: coder, store: store)
        _ = try await sut.fetch()

        await store.removeAllExternally()
        let restoredManagers = try await sut.fetch()
        let metrics = await store.metrics()

        #expect(restoredManagers.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.saveCount == 2)
        #expect((try? keychain.password(for: profile.id.uuidString)) != nil)
    }

    @Test
    func givenDuplicateManagers_whenFetch_thenKeepsOneManager() async throws {
        let profile = try newProfile()
        let keychain = MockKeychain()
        let coder = newKeychainCoder(keychain)
        let firstManager = try newManager(for: profile, coder: coder)
        let secondManager = try newManager(for: profile, coder: coder)
        let store = MockNETunnelManagerStore(managers: [firstManager, secondManager])
        let sut = newStrategy(coder: coder, store: store)

        let managers = try await sut.fetch()
        let metrics = await store.metrics()

        #expect(managers.count == 1)
        #expect(metrics.managerCount == 1)
        #expect(metrics.removeCount == 1)
    }
}

// MARK: - Helpers

private extension NEProtocolCoderTests {
    var bundleIdentifier: String {
        "com.example.MyTunnel"
    }

    func newKeychainCoder(_ keychain: Keychain) -> KeychainNEProtocolCoderV2 {
        KeychainNEProtocolCoderV2(
            .global,
            tunnelBundleIdentifier: bundleIdentifier,
            coder: CodingRegistry(registry: registry),
            keychain: keychain
        )
    }

    func newStrategy(
        coder: NEProtocolCoder,
        store: NETunnelManagerStore
    ) -> NETunnelStrategyV2 {
        NETunnelStrategyV2(
            .global,
            bundleIdentifier: bundleIdentifier,
            coder: coder,
            store: store,
            title: \.name
        )
    }

    func newManager(
        for profile: Profile,
        coder: NEProtocolCoder
    ) throws -> NETunnelProviderManager {
        let proto = try coder.protocolConfiguration(from: profile, title: \.name)
        var providerConfiguration = proto.providerConfiguration ?? [:]
        providerConfiguration["CustomProviderKey.profileId"] = profile.id.uuidString
        proto.providerConfiguration = providerConfiguration

        let manager = NETunnelProviderManager()
        manager.localizedDescription = profile.name
        manager.protocolConfiguration = proto
        return manager
    }

    func newProfile() throws -> Profile {
        var builder = Profile.Builder()
        builder.name = "foobar"
        builder.modules.append(try DNSModule.Builder(servers: ["2.4.2.4"]).build())
        builder.modules.append(try HTTPProxyModule.Builder(address: "1.1.1.1", port: 1080, pacURLString: "http://proxy.pac").build())
        builder.modules.append(IPModule.Builder(ipv4: .init(subnet: try .init("1.2.3.4", 16))).build())
        builder.modules.append(OnDemandModule.Builder().build())
        return try builder.build()
    }
}

private final class MockKeychain: Keychain, @unchecked Sendable {
    private struct Entry {
        let password: String

        let reference: Data
    }

    private let lock = NSLock()

    private var entriesByUsername: [String: Entry] = [:]

    private var usernamesByReference: [Data: String] = [:]

    func set(password: String, for username: String, label: String?) throws -> Data {
        guard let reference = username.data(using: .utf8) else {
            throw PartoutError(.encoding)
        }
        lock.lock()
        defer { lock.unlock() }
        entriesByUsername[username] = Entry(password: password, reference: reference)
        usernamesByReference[reference] = username
        return reference
    }

    func removePassword(for username: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entriesByUsername.removeValue(forKey: username) else {
            return false
        }
        usernamesByReference.removeValue(forKey: entry.reference)
        return true
    }

    func removePassword(forReference reference: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let username = usernamesByReference.removeValue(forKey: reference) else {
            return false
        }
        entriesByUsername.removeValue(forKey: username)
        return true
    }

    func password(for username: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let password = entriesByUsername[username]?.password else {
            throw PartoutError(.keychainItemNotFound)
        }
        return password
    }

    func passwordReference(for username: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let reference = entriesByUsername[username]?.reference else {
            throw PartoutError(.keychainItemNotFound)
        }
        return reference
    }

    func allPasswordReferences() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(usernamesByReference.keys)
    }

    func password(forReference reference: Data) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let username = usernamesByReference[reference],
              let password = entriesByUsername[username]?.password else {
            throw PartoutError(.keychainItemNotFound)
        }
        return password
    }
}

private actor MockNETunnelManagerStore: NETunnelManagerStore {
    struct Metrics: Sendable {
        let loadCount: Int

        let saveCount: Int

        let removeCount: Int

        let managerCount: Int
    }

    private var managers: [NETunnelProviderManager]

    private var saveFailures: Int

    private let loadDelay: Duration?

    private var loadCount = 0

    private var saveCount = 0

    private var removeCount = 0

    init(
        managers: [NETunnelProviderManager] = [],
        saveFailures: Int = 0,
        loadDelay: Duration? = nil
    ) {
        self.managers = managers
        self.saveFailures = saveFailures
        self.loadDelay = loadDelay
    }

    func loadAll() async throws -> [NETunnelProviderManager] {
        loadCount += 1
        if let loadDelay {
            try await Task.sleep(for: loadDelay)
        }
        return managers
    }

    func load(_ manager: NETunnelProviderManager) async throws {
    }

    func save(_ manager: NETunnelProviderManager) async throws {
        saveCount += 1
        if saveFailures > 0 {
            saveFailures -= 1
            throw MockNETunnelManagerStoreError.save
        }
        if !managers.contains(where: { $0 === manager }) {
            managers.append(manager)
        }
    }

    func remove(_ manager: NETunnelProviderManager) async throws {
        removeCount += 1
        managers.removeAll {
            $0 === manager
        }
    }

    func removeAllExternally() {
        managers.removeAll()
    }

    func metrics() -> Metrics {
        Metrics(
            loadCount: loadCount,
            saveCount: saveCount,
            removeCount: removeCount,
            managerCount: managers.count
        )
    }
}

private enum MockNETunnelManagerStoreError: Error {
    case save
}
#endif
