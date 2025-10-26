// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class DummyReachabilityObserver: ReachabilityObserver {
    func startObserving() {
    }

    var isReachable: Bool {
        true
    }

    // BEWARE that true will emit INFINITE events (CPU 100%)
    var isReachableStream: AsyncStream<Bool> {
        AsyncStream { nil }
    }
}
