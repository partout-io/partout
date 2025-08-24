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
        // FIXME: ###, POSIXSocket.waitForActivity() - handle timeout

        // FIXME: ###, POSIXSocket.waitForActivity() - pp_socket_open is blocking
        let closesOnEmptyRead = endpoint.proto.socketType == .tcp
        let maxReadLength = self.maxReadLength
        // FIXME: ###, drop this false
        if false && POSIXDispatchSourceSocket.isSupported {
            return try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXDispatchSourceSocket(
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        } else {
            return try AutoUpgradingSocket(endpoint: endpoint) {
                try POSIXBlockingSocket(
                    endpoint: $0,
                    closesOnEmptyRead: closesOnEmptyRead,
                    maxReadLength: maxReadLength
                )
            }
        }
    }
}
