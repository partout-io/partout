// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class POSIXInterfaceFactory: NetworkInterfaceFactory {
    private let ctx: PartoutLoggerContext

    private let betterPathBlock: AutoUpgradingLink.BetterPathBlock

    public init(
        _ ctx: PartoutLoggerContext,
        betterPathBlock: @escaping AutoUpgradingLink.BetterPathBlock
    ) {
        self.ctx = ctx
        self.betterPathBlock = betterPathBlock
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        POSIXSocketObserver(ctx, endpoint: endpoint, betterPathBlock: betterPathBlock)
    }
}
