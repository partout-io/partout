// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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
    func install(_ profile: Profile, connect: Bool, options: Sendable?) async throws

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
    nonisolated var didUpdateActiveProfiles: AsyncStream<[Profile.ID: TunnelSnapshot]> { get }
}

extension TunnelStrategy {
    public func install(_ profile: Profile, connect: Bool = false) async throws {
        try await install(profile, connect: connect, options: nil)
    }
}

extension TunnelStrategy {
    public func sendMessage(_ input: Message.Input, to profileId: Profile.ID) async throws -> Message.Output? {
        let encoded = try JSONEncoder.shared().encode(input)
        guard let output = try await sendMessage(encoded, to: profileId) else {
            return nil
        }
        return try JSONDecoder.shared().decode(Message.Output.self, from: output)
    }
}
