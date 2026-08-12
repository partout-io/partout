// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// Able to apply its own settings to `NEPacketTunnelNetworkSettings`.
public protocol NESettingsApplying {
    func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings)
}
