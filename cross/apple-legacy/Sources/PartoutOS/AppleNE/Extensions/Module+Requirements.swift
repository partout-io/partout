// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Module {
    public var requiresConnection: Bool {
        self is HTTPProxyModule || self is IPModule
    }
}
