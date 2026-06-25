// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TunnelControllerOptions {
    public init() {
        self.init(dnsFallbackServers: [], logsSnapshots: false, minDataCountDelta: .zero)
    }
}
