// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Defines the current tunnel profile.
public struct TunnelActiveProfile: Hashable, Sendable, CustomStringConvertible {
    public let id: Profile.ID

    public let status: TunnelStatus

    public let onDemand: Bool

    public init(id: Profile.ID, status: TunnelStatus, onDemand: Bool) {
        self.id = id
        self.status = status
        self.onDemand = onDemand
    }

    public var description: String {
        "{\(id.uuidString), status=\(status), onDemand=\(onDemand)}"
    }
}

/// Provides the underlying strategy of a ``Tunnel``.
public protocol TunnelStrategy: Sendable {

    /// Prepares the tunnel, e.g. fetches its initial status.
    ///
    /// - Parameters:
    ///   - purge: Performs a deep clean-up of stale profiles. Use carefully.
    func prepare(purge: Bool) async throws

    /// Installs the tunnel.
    ///
    /// - Parameters:
    ///   - profile: The ``Profile`` with which the tunnel must be configured.
    ///   - connect: Also initiate a connection.
    ///   - options: An optional set of connection options.
    ///   - title: The function of ``Profile`` to return a title.
    func install(
        _ profile: Profile,
        connect: Bool,
        options: Sendable?,
        title: @escaping @Sendable (Profile) -> String
    ) async throws

    /// Uninstalls the tunnel.
    ///
    /// - Parameters:
    ///     - profileId: The ID of the ``Profile`` to uninstall.
    func uninstall(profileId: Profile.ID) async throws

    /// Disconnects the tunnel.
    ///
    /// - Parameters:
    ///    - profileId: The ID of the ``Profile`` to uninstall.
    func disconnect(from profileId: Profile.ID) async throws

    /// Sends a message to the tunnel.
    ///
    /// - Parameters:
    ///    - message: The message.
    ///    - profileId: The ID of the ``Profile`` to send the message to.
    /// - Returns: An optional response from the tunnel.
    func sendMessage(_ message: Data, to profileId: Profile.ID) async throws -> Data?
}

/// Extends a strategy with observability.
public protocol TunnelObservableStrategy: TunnelStrategy {

    /// Publishes the unique changes in the current profiles.
    nonisolated var didUpdateActiveProfiles: AsyncStream<[Profile.ID: TunnelActiveProfile]> { get }
}

extension TunnelStrategy {
    public func install(_ profile: Profile, connect: Bool = false) async throws {
        try await install(profile, connect: connect, options: nil, title: \.name)
    }
}
