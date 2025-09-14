// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension FilterModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        disabledMask.forEach {
            switch $0 {
            case .ipv4:
                settings.ipv4Settings = nil
            case .ipv6:
                settings.ipv6Settings = nil
            case .dns:
                settings.dnsSettings = nil
            case .proxy:
                settings.proxySettings = nil
            case .mtu:
                settings.mtu = nil
                settings.tunnelOverheadBytes = nil
            @unknown default:
                break
            }
        }
    }
}
