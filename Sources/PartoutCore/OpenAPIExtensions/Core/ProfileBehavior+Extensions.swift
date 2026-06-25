// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
extension ProfileBehavior {
    public static let `default` = ProfileBehavior()

    public init() {
        self.init(disconnectsOnSleep: false, includesAllNetworks: false)
    }
}
