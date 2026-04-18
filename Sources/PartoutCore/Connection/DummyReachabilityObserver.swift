// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A ``ReachabilityObserver`` that never emits reachable events (for development).
public final class DummyReachabilityObserver: ReachabilityObserver {
    private let stream: CurrentValueStream<Bool>

    public init() {
        stream = CurrentValueStream(false)
    }

    public func startObserving() {
        stream.send(true)
    }

    public func stopObserving() {
        stream.finish()
    }

    public var isReachable: Bool {
        true
    }

    // BEWARE that true will emit INFINITE events (CPU 100%)
    public var isReachableStream: AsyncStream<Bool> {
        stream.subscribe()
    }
}
