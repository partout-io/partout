// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public final class POSIXSocketObserver: LinkObserver, @unchecked Sendable {
    private let endpoint: ExtendedEndpoint

    private let maxReadLength: Int

    public init(endpoint: ExtendedEndpoint, maxReadLength: Int = 128 * 1024) {
        self.endpoint = endpoint
        self.maxReadLength = maxReadLength
    }

    public func waitForActivity(timeout: Int) async throws -> LinkInterface {
        let socket: AutoUpgradingSocket
        let closesOnEmptyRead = endpoint.proto.socketType == .tcp
        let maxReadLength = self.maxReadLength

        // Use different implementations based on platform support
        if POSIXDispatchSourceSocket.isSupported {
            socket = try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXDispatchSourceSocket(
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        } else {
            socket = try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXBlockingSocket(
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        }

        // FIXME: ###, POSIXSocket.waitForActivity() - handle timeout
        try await socket.connect()
        return socket
    }
}
