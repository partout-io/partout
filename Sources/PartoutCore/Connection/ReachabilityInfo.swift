// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Platform-specific metadata about network reachability.
public struct ReachabilityInfo: Sendable {
    public let isReachable: Bool
#if os(Android)
    public let networkHandle: UInt64?
#endif

#if os(Android)
    public init(isReachable: Bool, networkHandle: UInt64?) {
        self.isReachable = isReachable
        self.networkHandle = networkHandle
    }
#else
    public init(isReachable: Bool) {
        self.isReachable = isReachable
    }
#endif
}
