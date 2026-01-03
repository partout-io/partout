// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// The common parameters used to create a ``Connection``.
public final class ConnectionParameters: Sendable {

    /// The ``Profile`` that originated the connection.
    public let profile: Profile

    /// The ``TunnelController`` to interact with the tunnel.
    public let controller: TunnelController

    /// The ``NetworkInterfaceFactory`` to create network interfaces.
    public let factory: NetworkInterfaceFactory

    /// The ``ReachabilityObserver`` to observe network events.
    public let reachability: ReachabilityObserver

    /// The ``TunnelEnvironment`` where to store shared values.
    public let environment: TunnelEnvironment

    /// The ``ConnectionParameters/Options-swift.struct`` to fine-tune (re)connection behavior.
    public let options: Options

    public init(
        profile: Profile,
        controller: TunnelController,
        factory: NetworkInterfaceFactory,
        reachability: ReachabilityObserver,
        environment: TunnelEnvironment,
        options: Options
    ) {
        self.profile = profile
        self.controller = controller
        self.factory = factory
        self.reachability = reachability
        self.environment = environment
        self.options = options
    }
}

extension ConnectionParameters {

    /// The options passed to a ``Connection`` at creation time.
    public struct Options: Sendable {

        /// The DNS resolution timeout.
        public var dnsTimeout = 3000

        /// The link activity timeout.
        public var linkActivityTimeout = 5000

        /// The link write timeout.
        public var linkWriteTimeout = 5000

        /// The minimum interval before updating data count.
        public var minDataCountInterval = 1000

        /// Generic user data.
        public var userInfo: Sendable?

        public init() {
        }
    }
}
