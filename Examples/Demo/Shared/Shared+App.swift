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
    static let shared = Registry(withKnown: true)
}

extension TunnelObservable {
    static let shared: TunnelObservable = {
#if targetEnvironment(simulator)
        let strategy = FakeTunnelStrategy()
        let tunnel = Tunnel(.global, strategy: strategy) {
            SharedTunnelEnvironment(profileId: $0)
        }
#else
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: Demo.tunnelBundleIdentifier,
            coder: Demo.neProtocolCoder
        )
        let tunnel = Tunnel(.global, strategy: strategy) {
            NETunnelEnvironment(strategy: strategy, profileId: $0)
        }
#endif
        return TunnelObservable(tunnel: tunnel)
    }()
}
