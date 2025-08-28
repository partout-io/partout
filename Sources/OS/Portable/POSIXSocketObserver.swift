// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class POSIXSocketObserver: LinkObserver, @unchecked Sendable {
    private let ctx: PartoutLoggerContext

    private let endpoint: ExtendedEndpoint

    private let betterPathBlock: BetterPathBlock

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        betterPathBlock: @escaping BetterPathBlock,
        maxReadLength: Int = 128 * 1024
    ) {
        self.ctx = ctx
        self.endpoint = endpoint
        self.betterPathBlock = betterPathBlock
        self.maxReadLength = maxReadLength
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {

        // Copy local constants to avoid strong retain on self in blocks
        let ctx = self.ctx
        let closesOnEmptyRead = endpoint.proto.socketType == .tcp
        let maxReadLength = self.maxReadLength

        // Use different I/O implementations based on platform support
        let link = try AutoUpgradingLink(
            endpoint: endpoint,
            ioBlock: {
                try POSIXBlockingSocket(
                    ctx,
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            },
            betterPathBlock: { [weak self] in
                guard let self else { throw PartoutError(.releasedObject) }
                return try betterPathBlock()
            }
        )

        // Establish actual connection
        try await link.connect(timeout: timeout)

        return link
    }
}
