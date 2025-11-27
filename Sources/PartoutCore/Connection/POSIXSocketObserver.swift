// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A ``LinkObserver`` spawning POSIX sockets.
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

        return try await AutoUpgradingLink(
            endpoint: endpoint,
            ioBlock: { endpoint in

                // POSIXBlockingSocket.init() does blocking I/O and MUST
                // be deferred to not block the actor
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().async {
                        do {
                            let socket = try POSIXBlockingSocket(
                                ctx,
                                to: endpoint,
                                timeout: timeout,
                                closesOnEmptyRead: closesOnEmptyRead,
                                maxReadLength: maxReadLength
                            )
                            continuation.resume(returning: socket)
                        } catch {
                            continuation.resume(throwing: PartoutError(.linkNotActive))
                        }
                    }
                }
            },
            betterPathBlock: { [weak self] in
                guard let self else { throw PartoutError(.releasedObject) }
                return try betterPathBlock()
            }
        )
    }
}
