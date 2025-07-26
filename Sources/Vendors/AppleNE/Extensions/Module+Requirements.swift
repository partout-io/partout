// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore

extension Module {
    public var requiresConnection: Bool {
        [.httpProxy, .ip].contains(moduleHandler.id)
    }
}
