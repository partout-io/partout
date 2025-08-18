// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import NetworkExtension
#if !PARTOUT_STATIC
import PartoutCore
#endif

/// A transient ``/PartoutCore/Module`` that embeds a full set of `NEPacketTunnelNetworkSettings`.
public struct NESettingsModule: Module, @unchecked Sendable {
    public let id: UUID

    public var fingerprint: Int {
        fullSettings.hashValue
    }

    private let fullSettings: NEPacketTunnelNetworkSettings

    public init(fullSettings: NEPacketTunnelNetworkSettings) {
        id = UUID()
        self.fullSettings = fullSettings
    }
}

extension NESettingsModule: NESettingsApplying {
    public func apply(_ ctx: PartoutLoggerContext, to settings: inout NEPacketTunnelNetworkSettings) {
        settings = fullSettings
    }
}

extension NESettingsModule: SensitiveDebugStringConvertible {
    public func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? fullSettings.debugDescription : "NEPacketTunnelNetworkSettings"
    }
}
