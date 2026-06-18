// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C

/// Platform-specific metadata about network reachability.
public struct ReachabilityInfo: Sendable {
    public let isReachable: Bool

#if os(Android)
    public let networkHandle: UInt64?
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

extension ReachabilityInfo {
    var toCReachability: pp_reachability {
#if os(Android)
        pp_reachability(
            reachable: isReachable,
            network_handle: networkHandle ?? 0
        )
#else
        pp_reachability(
            reachable: isReachable
        )
#endif
    }
}

extension pp_reachability {
    var fromCReachability: ReachabilityInfo {
#if os(Android)
        ReachabilityInfo(
            isReachable: reachable,
            networkHandle: network_handle != 0 ? network_handle : nil
        )
#else
        ReachabilityInfo(isReachable: reachable)
#endif
    }
}
