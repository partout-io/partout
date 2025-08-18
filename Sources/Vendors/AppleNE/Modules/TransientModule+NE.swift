// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension TransientModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        guard let transientSettings = object as? NEPacketTunnelNetworkSettings else {
            pp_log(ctx, .ne, .error, "Transient settings are not NEPacketTunnelNetworkSettings, ignoring")
            return
        }
        settings = transientSettings
    }
}
