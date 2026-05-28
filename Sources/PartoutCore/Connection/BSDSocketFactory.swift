// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``NetworkInterfaceFactory`` spawning BSD sockets.
public final class BSDSocketFactory: NetworkInterfaceFactory {
    private let ctx: PartoutLoggerContext

    private let betterPathFactory: BetterPathStreamFactory

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathFactory: BetterPathStreamFactory
    ) {
        self.ctx = ctx
        self.betterPathFactory = betterPathFactory
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        BSDSocketObserver(ctx, endpoint: endpoint, betterPathFactory: betterPathFactory)
    }
}
