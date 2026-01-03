// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

extension TransientModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        guard let transientSettings = object as? NEPacketTunnelNetworkSettings else {
            pp_log(ctx, .os, .error, "Transient settings are not NEPacketTunnelNetworkSettings, ignoring")
            return
        }
        settings = transientSettings
    }
}
