// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct TunnelTests {
    @Test
    func givenTunnel_whenNoActiveModules_thenFailsToConnect() async throws {
        let sut = try await newTunnel()
        let profile = try Profile.Builder().build()

        try await sut.prepare(purge: false)
        do {
            try await sut.install(profile, connect: true)
            #expect(Bool(false), "Connection should fail")
        } catch {
            //
        }
    }

    @Test
    func givenTunnel_whenOperate_thenStatusFollows() async throws {
        let sut = try await newTunnel()
        let module = IPModule.Builder().build()
        let profile = try Profile.Builder(modules: [module], activatingModules: true).build()
        let stream = sut.snapshotsStream

        let expected: [TunnelStatus] = [
            .inactive,
            .activating,
            .active,
            .deactivating,
            .inactive,
            .activating,
            .active,
            .inactive
        ]

        let pending = Task {
            var emitted: [TunnelStatus] = []
            for await snapshots in stream {
                if emitted.count == expected.count {
                    return emitted
                }
                guard let status = snapshots.first?.value.status else {
                    continue
                }
                // Skip duplicates
                guard status != emitted.last else {
                    continue
                }
                emitted.append(status)
            }
            return emitted
        }

        try await sut.prepare(purge: false)
        try await sut.install(profile, connect: true)
        try await sut.disconnect(from: profile.id)
        try await sut.install(profile, connect: true)
        try await sut.uninstall(profileId: profile.id)

        let emitted = await pending.value
        #expect(emitted == expected)
    }

    @Test
    func givenTunnel_whenDisconnectWithError_thenPublishesLastErrorCode() async throws {
        let env = SharedTunnelEnvironment(profileId: nil)
        let sut = try await newTunnel(env: env)

        let module = IPModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()
        try await sut.connect(with: profile)
        env.setEnvironmentValue(.crypto, forKey: TunnelEnvironmentKeys.lastErrorCode)

        let exp = Expectation()
        let stream = sut.snapshotsStream
        var didCall = false
        Task {
            for await _ in stream {
                if !didCall, sut.snapshots[profile.id]?.environment?.lastErrorCode != nil {
                    didCall = true
                    await exp.fulfill()
                }
            }
        }

        try await sut.disconnect(from: profile.id)
        try await exp.fulfillment(timeout: 500)
        let error = sut.snapshots[profile.id]?.environment?.lastErrorCode
        switch error {
        case .crypto:
            break
        default:
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test
    func givenTunnel_whenPublishesDataCount_thenIsAvailable() async throws {
        let env = SharedTunnelEnvironment(profileId: nil)
        let sut = try await newTunnel(env: env)
        let stream = sut.snapshotsStream
        #expect(await stream.nextElement() == [:])

        let module = IPModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()

        try await sut.connect(with: profile)
        let active = try await #require(stream.nextElement())
        #expect(active.first?.key == profile.id)

        let expDataCount = DataCount(500, 700)
        env.setEnvironmentValue(expDataCount, forKey: TunnelEnvironmentKeys.dataCount)

        for await next in stream {
            let dataCount = next[profile.id]?.environment?.dataCount
            guard dataCount == expDataCount else {
                continue
            }
            // Success
            return
        }
    }

    @Test
    func givenTunnelAndProcessor_whenInstall_thenProcessesProfile() async throws {
        let env = SharedTunnelEnvironment(profileId: nil)
        let processor = MockTunnelProcessor()
        let sut = try await newTunnel(env: env, processor: processor)
        let stream = sut.snapshotsStream
        #expect(await stream.nextElement() == [:])

        let module = IPModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()

        try await sut.install(profile)
        let active = try await #require(stream.nextElement())

        #expect(active.first?.key == profile.id)
        //        #expect(processor.titleCount == 1) // unused by FakeTunnelStrategy
        #expect(processor.willInstallCount == 1)
    }

    @Test
    func givenTunnel_whenStatusChanges_thenConnectionStatusIsExpected() async throws {
        let env = SharedTunnelEnvironment(profileId: nil)
        let processor = MockTunnelProcessor()
        let sut = try await newTunnel(env: env, processor: processor)
        let stream = sut.snapshotsStream
        #expect(await stream.nextElement() == [:])

        let module = IPModule.Builder().build()
        let profile = try Profile.Builder(modules: [module]).build()

        try await sut.install(profile)
        let pulled = try await #require(stream.nextElement())

        #expect(pulled.first?.key == profile.id)
        //        #expect(processor.titleCount == 1) // unused by FakeTunnelStrategy
        #expect(processor.willInstallCount == 1)
    }

    @Test
    func givenTunnelStatus_thenConnectionStatusIsExpected() async throws {
        let allTunnelStatuses: [TunnelStatus] = [
            .inactive,
            .activating,
            .active,
            .deactivating
        ]
        let allConnectionStatuses: [ConnectionStatus] = [
            .disconnected,
            .connecting,
            .connected,
            .disconnecting
        ]

        // No connection status, tunnel status unaffected
        allTunnelStatuses.forEach {
            #expect($0.considering(nil) == $0)
        }

        // Has connection status
        var env = TunnelSnapshot.Environment()

        // Affected if .active
        let tunnelActive: TunnelStatus = .active
        env = env.with(connectionStatus: .connected)
        #expect(tunnelActive.considering(env) == .active)
        allConnectionStatuses
            .forEach {
                env = env.with(connectionStatus: $0)
                let statusWithEnv = tunnelActive.considering(env)
                switch $0 {
                case .connecting:
                    #expect(statusWithEnv == .activating)
                case .connected:
                    #expect(statusWithEnv == .active)
                case .disconnecting:
                    #expect(statusWithEnv == .deactivating)
                case .disconnected:
                    #expect(statusWithEnv == .inactive)
                }
            }

        // Unaffected otherwise
        allTunnelStatuses
            .filter {
                $0 != .active
            }
            .forEach {
                #expect($0.considering(env) == $0)
            }
    }

    @Test
    func givenTunnelSnapshot_whenEnvironmentConnectionStatusChanges_thenStatusConsidersIt() async throws {
        var env = TunnelSnapshot.Environment()
        env = env.with(connectionStatus: .connecting)
        let snapshot = TunnelSnapshot(
            id: UniqueID(),
            isEnabled: true,
            status: .active,
            onDemand: false,
            environment: env
        )
        #expect(snapshot.status.considering(env) == .activating)

        env = env.with(connectionStatus: .connected)
        let updated = snapshot.with(environment: env)
        #expect(updated.status.considering(env) == .active)
    }
}

// MARK: - Helpers

private extension TunnelTests {
    func newTunnel(
        env: TunnelEnvironment? = nil,
        processor: MockTunnelProcessor? = nil
    ) async throws -> Tunnel {
        let tunnel = Tunnel(
            .global,
            strategy: FakeTunnelStrategy(delay: 100),
            refreshInterval: 100,
            willInstall: processor?.willInstall,
            environmentFactory: { @Sendable _ in
                env ?? SharedTunnelEnvironment(profileId: nil)
            }
        )
        try await tunnel.prepare(purge: false)
        return tunnel
    }
}

private extension Tunnel {
    func connect(with profile: Profile) async throws {
        try await install(profile, connect: true)
    }
}

private final class MockTunnelProcessor: @unchecked Sendable {
    var willInstallCount = 0

    @Sendable
    func willInstall(_ preProfile: Profile, connect: Bool) throws -> Profile {
        willInstallCount += 1
        return profile
    }
}
