// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension

/// The Network Extension preferences operations used by tunnel strategies.
///
/// Keeping these operations behind a value makes strategy behavior testable
/// without reading or mutating the host's actual VPN preferences.
struct NETunnelPreferences: @unchecked Sendable {
    let loadAll: @Sendable () async throws -> [NETunnelProviderManager]

    let load: @Sendable (NETunnelProviderManager) async throws -> Void

    let save: @Sendable (NETunnelProviderManager) async throws -> Void

    let remove: @Sendable (NETunnelProviderManager) async throws -> Void
}

extension NETunnelPreferences {
    static let live = NETunnelPreferences(
        loadAll: {
            try await NETunnelProviderManager.loadAllFromPreferences()
        },
        load: {
            try await $0.loadFromPreferences()
        },
        save: {
            try await $0.saveToPreferences()
        },
        remove: {
            try await $0.removeFromPreferences()
        }
    )
}
