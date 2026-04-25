// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``NetworkInterfaceFactory`` spawning BSD sockets.
public final class BSDSocketFactory: NetworkInterfaceFactory {
    private let ctx: PartoutLoggerContext

    private let betterPathBlock: BetterPathBlock

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathBlock: @escaping BetterPathBlock
    ) {
        self.ctx = ctx
        self.betterPathBlock = betterPathBlock
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        BSDSocketObserver(ctx, endpoint: endpoint, betterPathBlock: betterPathBlock)
    }
}
