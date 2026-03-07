// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Observation

/// Wraps a tunnel for use in the UI.
@available(iOS 17, macOS 14, tvOS 17, *)
@MainActor @Observable
public final class TunnelObservable {
    private let tunnel: Tunnel

    public private(set) var statuses: [Profile.ID: TunnelStatus]

    public init(tunnel: Tunnel) {
        self.tunnel = tunnel
        statuses = [:]
        Task {
            let stream: AsyncStream<[Profile.ID: TunnelActiveProfile]>
            do {
                try await tunnel.prepare(purge: false)
                stream = tunnel.activeProfilesStream
                for await active in stream {
                    statuses = active.mapValues(\.status)
                }
            } catch {
                pp_log_g(.core, .fault, "Unable to prepare tunnel: \(error)")
            }
        }
    }

    public var status: TunnelStatus {
        statuses.first?.value ?? .inactive
    }

    public func install(_ profile: Profile, title: @escaping @Sendable (Profile) -> String) async throws {
        try await tunnel.install(profile, connect: false, title: title)
    }

    public func connect(to profile: Profile, title: @escaping @Sendable (Profile) -> String) async throws {
        try await tunnel.install(profile, connect: true, title: title)
    }

    public func disconnect(from profileId: Profile.ID) async throws {
        try await tunnel.disconnect(from: profileId)
    }

    public func sendMessage(_ input: Message.Input, to profileId: Profile.ID) async throws -> Message.Output? {
        try await tunnel.sendMessage(input, to: profileId)
    }

    public func environment(for profileId: Profile.ID) async -> TunnelEnvironmentReader? {
        await tunnel.environment(for: profileId)
    }
}
