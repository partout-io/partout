// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class MockNetworkInterfaceFactory: NetworkInterfaceFactory, @unchecked Sendable {
    public var observerBlock: (MockLinkObserver) -> Void = { _ in }

    public var linkBlock: (MockLinkInterface) -> Void = { _ in }

    public init() {
    }

    public func currentReachability() -> ReachabilityInfo? {
        nil
    }

    public func linkObserver(
        to endpoint: ExtendedEndpoint,
        reachability: ReachabilityInfo?,
    ) -> LinkObserver {
        let newObserver = MockLinkObserver(to: endpoint, linkBlock: linkBlock)
        observerBlock(newObserver)
        return newObserver
    }
}
