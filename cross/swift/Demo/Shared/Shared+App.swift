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
        let strategy = LegacyNETunnelStrategy(
            .global,
            bundleIdentifier: Demo.tunnelBundleIdentifier,
            coder: Demo.neProtocolCoder
        )
        let tunnel = Tunnel(.global, strategy: strategy) {
            NETunnelEnvironment(profileId: $0) {
                let output = try await strategy.sendMessage(.environment(), to: $0)
                switch output {
                case .environment(let env):
                    return env
                default:
                    return nil
                }
            }
        }
#endif
        return PartoutTunnelObservable(tunnel: tunnel)
    }()
}
