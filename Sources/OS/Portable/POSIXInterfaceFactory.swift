// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class POSIXInterfaceFactory: NetworkInterfaceFactory {
    private let ctx: PartoutLoggerContext

    public init(_ ctx: PartoutLoggerContext, blocking: Bool = false) {
        self.ctx = ctx
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        POSIXSocketObserver(ctx, endpoint: endpoint)
    }
}
