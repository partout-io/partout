// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

@MainActor
struct TunnelTests {
    @Test
    func givenTunnel_whenNoActiveModules_thenFailsToConnect() async throws {
        let sut = newTunnel()
        let profile = try Profile.Builder().build()

        try await sut.prepare(purge: false)
        do {
            try await sut.install(profile, connect: true, title: \.name)
            #expect(Bool(false), "Connection should fail")
        } catch {
            //
        }
    }

    @Test
    func givenTunnel_whenOperate_thenStatusFollows() async throws {
        let sut = newTunnel()
        let module = try DNSModule.Builder().build()
        let profile = try Profile.Builder(modules: [module], activatingModules: true).build()
        let stream = sut.activeProfilesStream.removeDuplicates()

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
            for await activeProfiles in stream {
                if emitted.count == expected.count {
                    return emitted
                }
                guard let status = activeProfiles.first?.value.status else {
                    continue
                }
                emitted.append(status)
            }
            return emitted
        }

        try await sut.prepare(purge: false)
        try await sut.install(profile, connect: true, title: \.name)
        try await sut.disconnect(from: profile.id)
        try await sut.install(profile, connect: true, title: \.name)
        try await sut.uninstall(profileId: profile.id)

        let emitted = await pending.value
        #expect(emitted == expected)
    }
}

// MARK: - Helpers

private extension TunnelTests {
    func newTunnel() -> Tunnel {
        Tunnel(.global, strategy: FakeTunnelStrategy(delay: 0)) { _ in
            SharedTunnelEnvironment(profileId: nil)
        }
    }
}
