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

extension PartoutTunnelObservable {
    static let shared: PartoutTunnelObservable = {
#if targetEnvironment(simulator)
        let strategy = FakeTunnelStrategy()
        let tunnel = Tunnel(.global, strategy: strategy) {
            SharedTunnelEnvironment(profileId: $0)
        }
#else
        let strategy = NETunnelStrategy(
            .global,
            bundleIdentifier: Demo.tunnelBundleIdentifier,
            coder: Demo.neProtocolCoder,
            title: {
                "PartoutDemo: \($0.name)"
            }
        )
        let tunnel = Tunnel(.global, strategy: strategy) {
            NETunnelEnvironment(strategy: strategy, profileId: $0)
        }
#endif
        return PartoutTunnelObservable(tunnel: tunnel)
    }()
}
