// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``LinkObserver`` spawning BSD sockets.
public final class BSDSocketObserver: LinkObserver, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let endpoint: ExtendedEndpoint

    private let betterPathFactory: BetterPathStreamFactory

    private let configurator: SocketConfigurator?

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        betterPathFactory: BetterPathStreamFactory,
        configurator: SocketConfigurator?,
        maxReadLength: Int = 128 * 1024
    ) {
        self.ctx = ctx
        self.endpoint = endpoint
        self.betterPathFactory = betterPathFactory
        self.configurator = configurator
        self.maxReadLength = maxReadLength
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        try await BSDSocket.connect(
            ctx,
            endpoint: endpoint,
            timeout: timeout,
            betterPathFactory: betterPathFactory,
            configurator: configurator,
            maxReadLength: maxReadLength
        )
    }
}
