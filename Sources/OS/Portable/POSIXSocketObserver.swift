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

    private let betterPathBlock: AutoUpgradingLink.BetterPathBlock

    private let maxReadLength: Int

    public init(
        _ ctx: PartoutLoggerContext,
        endpoint: ExtendedEndpoint,
        betterPathBlock: @escaping AutoUpgradingLink.BetterPathBlock,
        maxReadLength: Int = 128 * 1024
    ) {
        self.ctx = ctx
        self.endpoint = endpoint
        self.betterPathBlock = betterPathBlock
        self.maxReadLength = maxReadLength
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        let link: AutoUpgradingLink

        // Copy local constants to avoid strong retain on self in blocks
        let ctx = self.ctx
        let closesOnEmptyRead = endpoint.proto.socketType == .tcp
        let maxReadLength = self.maxReadLength

        // Use different implementations based on platform support
        do {
            link = try AutoUpgradingLink(
                endpoint: endpoint,
                ioBlock: { [weak self] in
                    guard let self else { throw PartoutError(.releasedObject) }
                    return try POSIXDispatchSourceSocket(
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
        } catch let error as PartoutError {
            // POSIXDispatchSourceSocket throws .unhandled if unsupported
            guard error.code == .unhandled else {
                throw error
            }
            link = try AutoUpgradingLink(
                endpoint: endpoint,
                ioBlock: { [weak self] in
                    guard let self else { throw PartoutError(.releasedObject) }
                    return try POSIXBlockingSocket(
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
        }

        // Establish actual connection
        try await link.connect(timeout: timeout)

        return link
    }
}
