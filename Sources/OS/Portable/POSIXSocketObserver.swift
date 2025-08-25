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

    private let maxReadLength: Int

    public init(_ ctx: PartoutLoggerContext, endpoint: ExtendedEndpoint, maxReadLength: Int = 128 * 1024) {
        self.ctx = ctx
        self.endpoint = endpoint
        self.maxReadLength = maxReadLength
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        let socket: AutoUpgradingSocket

        // Copy local constants to avoid strong retain on self in blocks
        let ctx = self.ctx
        let closesOnEmptyRead = endpoint.proto.socketType == .tcp
        let maxReadLength = self.maxReadLength

        // Use different implementations based on platform support
        do {
            socket = try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXDispatchSourceSocket(
                    ctx,
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        } catch let error as PartoutError {
            // POSIXDispatchSourceSocket throws .unhandled if unsupported
            guard error.code == .unhandled else {
                throw error
            }
            socket = try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXBlockingSocket(
                    ctx,
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        }
        try await socket.connect(timeout: timeout)
        return socket
    }
}
