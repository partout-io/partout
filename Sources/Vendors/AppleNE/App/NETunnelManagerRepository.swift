// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
import PartoutCore

/// Offers an API to manage the installed set of NETunnelProviderManager.
public protocol NETunnelManagerRepository {
    func fetch() async throws -> [NETunnelProviderManager]

    func save(
        _ profile: Profile,
        forConnecting: Bool,
        options: [String: NSObject]?,
        title: (Profile) -> String
    ) async throws

    func remove(profileId: Profile.ID) async throws

    func profile(from manager: NETunnelProviderManager) throws -> Profile

    var managersStream: AsyncStream<[Profile.ID: NETunnelProviderManager]> { get }
}
