// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``ReachabilityObserver`` that never emits reachable events (for development).
public final class DummyReachabilityObserver: ReachabilityObserver {
    public init() {}

    public func startObserving() {
    }

    public var isReachable: Bool {
        true
    }

    // BEWARE that true will emit INFINITE events (CPU 100%)
    public var isReachableStream: AsyncStream<Bool> {
        AsyncStream { nil }
    }
}
