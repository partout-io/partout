// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

public final class NativeSocketFactory: NetworkInterfaceFactory {
    private struct Observer: LinkObserver {
        let factory: NativeSocketFactory
        let endpoint: ExtendedEndpoint

        func waitForActivity(timeout: Int) async throws -> LinkInterface {
            try await SocketWrapper(
                factory.ctx,
                options: SocketWrapper.Options(
                    endpoint: endpoint,
                    timeout: timeout,
                    bufSize: factory.bufSize,
                    betterPathStream: factory.betterPathFactory.newStream(),
                    reachability: nil,
                    configure: nil,
                    configureCtx: nil
                )
            )
        }
    }

    private let ctx: PartoutLoggerContext
    private let betterPathFactory: BetterPathStreamFactory
    private let bufSize: Int

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory,
        bufSize: Int = 1 * 1024 * 1024, // 1MB
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
        self.bufSize = bufSize
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit NativeSocketFactory")
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        Observer(factory: self, endpoint: endpoint)
    }
}
