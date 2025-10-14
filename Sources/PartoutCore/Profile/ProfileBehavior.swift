// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public struct ProfileBehavior: Hashable, Codable, Sendable {
    public var disconnectsOnSleep: Bool
    public var includesAllNetworks: Bool?

    public init() {
        disconnectsOnSleep = false
        includesAllNetworks = false
    }
}
