// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutNative

extension Demo {
    static func parseModule<M>(_ type: M.Type, url: URL) throws -> M? where M: Decodable {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let cJSON = partout_import_module(text) else { return nil }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }
        let tagged = try JSONDecoder.shared().decode(TaggedModule.self, from: jsonData)
        return tagged.containedModule as? M
    }
}

extension Demo.Log {
    static let appURL = Demo.cachesURL.appending(component: "app.log")
}

// MARK: - Implementations

extension PartoutTunnelObservable {
    static let repository = SingleProfileRepository(profile: .demo)

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
            source: repository.source,
            coder: Demo.neProtocolCoder,
            fingerprint: { _ in UUID().uuidString }
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
