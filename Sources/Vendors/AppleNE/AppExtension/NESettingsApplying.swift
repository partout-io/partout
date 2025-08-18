// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_STATIC
import PartoutCore
#endif

/// Able to apply its own settings to `NEPacketTunnelNetworkSettings`.
public protocol NESettingsApplying {
    func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings)
}
