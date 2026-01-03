// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class POSIXInterfaceFactory: NetworkInterfaceFactory {
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
        POSIXSocketObserver(ctx, endpoint: endpoint, betterPathBlock: betterPathBlock)
    }
}
