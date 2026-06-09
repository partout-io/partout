// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Provides methods to configure sockets on a native platform.
public final class SocketConfigurator: Sendable {
    public let reachability: @Sendable () -> ReachabilityInfo?
    public let configureSocket: @Sendable (_ fd: FileDescriptor) -> Bool

    public init(
        reachability: @Sendable @escaping () -> ReachabilityInfo?,
        configureSocket: @Sendable @escaping (_: FileDescriptor) -> Bool
    ) {
        self.reachability = reachability
        self.configureSocket = configureSocket
    }
}
