// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Publishes path updates.
public protocol ReachabilityObserver: AnyObject, Sendable {

    /// Starts observing network events.
    func startObserving()

    /// True if the network is currently reachable.
    var isReachable: Bool { get }

    /// Publishes whether the network is reachable.
    var isReachableStream: AsyncStream<Bool> { get }
}
