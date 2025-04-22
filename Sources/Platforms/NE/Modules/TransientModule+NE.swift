//
//  TransientModule+NE.swift
//  Partout
//
//  Created by Davide De Rosa on 4/14/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import NetworkExtension
import PartoutCore

extension TransientModule: NESettingsApplying {
    public func apply(to settings: inout NEPacketTunnelNetworkSettings) {
        guard let transientSettings = object as? NEPacketTunnelNetworkSettings else {
            pp_log(.ne, .error, "Transient settings are not NEPacketTunnelNetworkSettings, ignoring")
            return
        }
        settings = transientSettings
    }
}
