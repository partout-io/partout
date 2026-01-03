// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Module {
    public var requiresConnection: Bool {
        [.httpProxy, .ip].contains(moduleHandler.id)
    }
}
