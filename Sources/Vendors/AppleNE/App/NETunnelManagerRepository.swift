// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
import PartoutCore

/// Offers an API to manage the installed set of NETunnelProviderManager.
public protocol NETunnelManagerRepository {
    func fetch() async throws -> [NETunnelProviderManager]

    func save<O>(
        _ profile: Profile,
        forConnecting: Bool,
        options: O?,
        title: @Sendable (Profile) -> String
    ) async throws where O: Sendable

    func remove(profileId: Profile.ID) async throws

    func profile(from manager: NETunnelProviderManager) throws -> Profile

    var managersStream: AsyncStream<[Profile.ID: NETunnelProviderManager]> { get }
}
