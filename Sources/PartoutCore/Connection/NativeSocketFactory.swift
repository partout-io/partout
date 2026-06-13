// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``NetworkInterfaceFactory`` that spawns native BSD sockets.
public final class NativeSocketFactory: NetworkInterfaceFactory {
    public typealias ConfigureSocket = @Sendable (SocketDescriptor, ReachabilityInfo?) -> Bool

    private struct Observer: LinkObserver {
        let factory: NativeSocketFactory
        let endpoint: ExtendedEndpoint
        let reachability: ReachabilityInfo?

        func waitForActivity(timeout: Int) async throws -> LinkInterface {
            let configureCtx = Unmanaged.passUnretained(factory).toOpaque()
            let options = SocketWrapper.Options(
                endpoint: endpoint,
                timeout: timeout,
                bufSize: factory.bufSize,
                betterPathStream: factory.betterPathFactory.newStream(),
                reachability: reachability?.toCReachability,
                configure: { ctx, fd, reachability in
                    guard let ctx else { return true }
                    let factory = Unmanaged<NativeSocketFactory>
                        .fromOpaque(ctx)
                        .takeUnretainedValue()
                    guard let cfg = factory.configureSocket else { return true }
                    return cfg(fd, reachability?.pointee.fromCReachability)
                },
                configureCtx: configureCtx
            )
            return try await SocketWrapper(
                factory.ctx,
                options: options
            )
        }
    }

    private let ctx: PartoutLoggerContext
    private let currentReachabilityBlock: (@Sendable () -> ReachabilityInfo?)?
    private let betterPathFactory: BetterPathStreamFactory
    private let configureSocket: ConfigureSocket?
    private let bufSize: Int

    public init(
        _ ctx: PartoutLoggerContext,
        currentReachabilityBlock: (@Sendable () -> ReachabilityInfo?)?,
        betterPathFactory: BetterPathStreamFactory,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.currentReachabilityBlock = currentReachabilityBlock
        self.betterPathFactory = betterPathFactory
        configureSocket = nil
        self.bufSize = bufSize
    }

    init(
        _ ctx: PartoutLoggerContext,
        currentReachabilityBlock: (@Sendable () -> ReachabilityInfo?)?,
        betterPathFactory: BetterPathStreamFactory,
        configureSocket: ConfigureSocket?,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.currentReachabilityBlock = currentReachabilityBlock
        self.betterPathFactory = betterPathFactory
        self.configureSocket = configureSocket
        self.bufSize = bufSize
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeSocketFactory")
    }

    public func currentReachability() -> ReachabilityInfo? {
        currentReachabilityBlock?()
    }

    public func linkObserver(
        to endpoint: ExtendedEndpoint,
        reachability: ReachabilityInfo?
    ) -> LinkObserver {
        return Observer(factory: self, endpoint: endpoint, reachability: reachability)
    }
}
