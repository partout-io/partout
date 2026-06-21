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

    /// The ``TunnelEnvironment`` backing the connection state.
    public let environment: TunnelEnvironment

    /// The ``ConnectionParameters/Options-swift.struct`` to fine-tune (re)connection behavior.
    public let options: Options

    /// The ``ConnectionReporter`` where connections can report to.
    public let reporter: ConnectionReporter

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
        reporter = ConnectionReporter(.init(profile.id), environment: environment)
    }
}

/// Reports connection-originated values without exposing the whole tunnel environment to connections.
public final class ConnectionReporter: Sendable {
    private let ctx: PartoutLoggerContext
    private let environment: TunnelEnvironment

    public init(_ ctx: PartoutLoggerContext, environment: TunnelEnvironment) {
        self.ctx = ctx
        self.environment = environment
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit ConnectionReporter")
    }

    public func reportDataCount(_ dataCount: DataCount) {
        reportEnvironmentValue(dataCount, forKey: TunnelEnvironmentKeys.dataCount)
    }

    public func clearDataCount() {
        clearEnvironmentValue(forKey: TunnelEnvironmentKeys.dataCount)
    }

    public func reportEnvironmentValue<T>(_ value: T, forKey key: TunnelEnvironmentKey<T>) where T: Encodable {
        environment.setEnvironmentValue(value, forKey: key)
    }

    public func clearEnvironmentValue<T>(forKey key: TunnelEnvironmentKey<T>) {
        environment.removeEnvironmentValue(forKey: key)
    }

    public func reportLastError(_ error: Error) {
        reportLastErrorCode(error.partoutErrorCode)
    }

    public func reportLastErrorCode(_ code: PartoutError.Code) {
        reportEnvironmentValue(code.rawValue, forKey: TunnelEnvironmentKeys.lastErrorCode)
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
