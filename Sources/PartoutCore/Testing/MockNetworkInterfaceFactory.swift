// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public final class MockNetworkInterfaceFactory: NetworkInterfaceFactory, @unchecked Sendable {
    public var observerBlock: (MockLinkObserver) -> Void = { _ in }

    public var linkBlock: (MockLinkInterface) -> Void = { _ in }

    public init() {
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver {
        let newObserver = MockLinkObserver(to: endpoint, linkBlock: linkBlock)
        observerBlock(newObserver)
        return newObserver
    }
}
