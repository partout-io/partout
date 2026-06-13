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
    private let betterPathFactory: BetterPathStreamFactory
    private let currentReachability: (@Sendable () -> ReachabilityInfo?)?
    private let configureSocket: ConfigureSocket?
    private let bufSize: Int

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
        currentReachability = nil
        configureSocket = nil
        self.bufSize = bufSize
    }

    init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory,
        currentReachability: (@Sendable () -> ReachabilityInfo?)?,
        configureSocket: ConfigureSocket?,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
        self.currentReachability = currentReachability
        self.configureSocket = configureSocket
        self.bufSize = bufSize
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeSocketFactory")
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        let reachability = currentReachability?()
        return Observer(factory: self, endpoint: endpoint, reachability: reachability)
    }
}
