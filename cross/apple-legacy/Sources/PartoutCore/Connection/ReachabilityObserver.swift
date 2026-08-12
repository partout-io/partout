// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Publishes path updates.
public protocol ReachabilityObserver: AnyObject, Sendable {
    /// Starts observing network events.
    func startObserving()

    /// Stops observing network events.
    func stopObserving()

    /// True if the network is currently reachable.
    var isReachable: Bool { get }

    /// Publishes whether the network is reachable.
    var isReachableStream: AsyncStream<Bool> { get }
}
