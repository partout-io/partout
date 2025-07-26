// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

extension Demo.Log {
    static let appURL = Demo.cachesURL.appending(component: "app.log")
}

// MARK: - Implementations

extension Registry {
    static let shared = Registry()
}

extension Tunnel {
    static let shared: Tunnel = {
#if targetEnvironment(simulator)
        let strategy = FakeTunnelStrategy()
        return Tunnel(strategy: strategy) { _ in
            SharedTunnelEnvironment()
        }
#else
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: Demo.tunnelBundleIdentifier,
            coder: Demo.neProtocolCoder
        )
        return Tunnel(.global, strategy: strategy) {
            NETunnelEnvironment(strategy: strategy, profileId: $0)
        }
#endif
    }()
}
