//
//  NETunnelInterface.swift
//  Partout
//
//  Created by Davide De Rosa on 8/27/17.
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

import Foundation
import NetworkExtension
import PartoutCore

/// Implementation of a `TunnelInterface` via `NEPacketTunnelFlow`.
public final class NETunnelInterface: TunnelInterface {
    private let ctx: PartoutLoggerContext

    private weak var impl: NEPacketTunnelFlow?

    public init(_ ctx: PartoutLoggerContext, impl: NEPacketTunnelFlow) {
        self.ctx = ctx
        self.impl = impl
    }

    // MARK: TunnelInterface

    public func readPackets() async throws -> [Data] {
        guard let impl else {
            pp_log(ctx, .ne, .error, "NEPacketTunnelFlow released prematurely")
            throw PartoutError(.unhandled)
        }
        let pair = await impl.readPackets()
        return pair.0
    }

    public func writePackets(_ packets: [Data]) {
        let protocols = packets.map(IPHeader.protocolNumber(inPacket:))
        impl?.writePackets(packets, withProtocols: protocols)
    }
}
