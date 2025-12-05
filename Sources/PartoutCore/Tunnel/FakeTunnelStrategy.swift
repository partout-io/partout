// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Implementation of ``TunnelObservableStrategy`` to fake VPN operation on simulators.
public actor FakeTunnelStrategy: TunnelObservableStrategy, Sendable {
    private nonisolated let activeProfileSubject: CurrentValueStream<UniqueID, TunnelActiveProfile?>

    private var status: TunnelStatus {
        get {
            activeProfileSubject.value?.status ?? .inactive
        }
        set {
            guard let previous = activeProfileSubject.value else {
                return
            }
            activeProfileSubject.send(.init(
                id: previous.id,
                status: newValue,
                onDemand: previous.onDemand
            ))
        }
    }

    public nonisolated var activeProfiles: [Profile.ID: TunnelActiveProfile] {
        guard let current = activeProfileSubject.value else {
            return [:]
        }
        return [current.id: current]
    }

    public nonisolated var activeProfile: TunnelActiveProfile? {
        activeProfileSubject.value
    }

    public nonisolated var didUpdateActiveProfiles: AsyncStream<[Profile.ID: TunnelActiveProfile]> {
        activeProfileSubject
            .subscribe()
            .map {
                guard let current = $0 else {
                    return [:]
                }
                return [current.id: current]
            }
    }

    private let delay: Int

    private let onMessage: @Sendable (Data) -> Data

    public init(
        delay: Int = 1000,
        onMessage: @escaping @Sendable (Data) -> Data = { $0 }
    ) {
        self.delay = delay
        self.onMessage = onMessage
        activeProfileSubject = CurrentValueStream(nil)
    }

    public func prepare(purge: Bool) async throws {
    }

    public func install(
        _ profile: Profile,
        connect: Bool,
        options: Sendable?,
        title: @escaping @Sendable (Profile) -> String
    ) async throws {
        let isOnDemand = profile.activeModules
            .contains {
                $0 is OnDemandModule
            }
        if connect, status != .inactive {
            await doDisconnect()
        }
        if isOnDemand {
            activeProfileSubject.send(TunnelActiveProfile(
                id: profile.id,
                status: .inactive,
                onDemand: true
            ))
        } else {
            activeProfileSubject.send(TunnelActiveProfile(
                id: profile.id,
                status: .inactive,
                onDemand: false
            ))
            if connect {
                await doConnect()
            }
        }
    }

    public func uninstall(profileId: Profile.ID) async throws {
        if profileId == activeProfileSubject.value?.id {
            status = .inactive
            activeProfileSubject.send(nil)
        }
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        await doDisconnect()
        activeProfileSubject.send(TunnelActiveProfile(
            id: profileId,
            status: .inactive,
            onDemand: false
        ))
    }

    public func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data? {
        onMessage(message)
    }
}

private extension FakeTunnelStrategy {
    func doConnect() async {
        status = .activating
        try? await Task.sleep(milliseconds: delay)
        if status == .activating {
            status = .active
        }
    }

    func doDisconnect() async {
        guard status != .inactive else {
            return
        }
        status = .deactivating
        try? await Task.sleep(milliseconds: delay)
        if status == .deactivating {
            status = .inactive
        }
    }
}
