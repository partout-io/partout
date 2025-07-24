//
//  NEInterfaceFactory.swift
//  Partout
//
//  Created by Davide De Rosa on 3/15/24.
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
@preconcurrency import NetworkExtension
import PartoutCore

/// A ``/PartoutCore/NetworkInterfaceFactory`` that spawns ``/PartoutCore/LinkInterface`` and ``/PartoutCore/TunnelInterface`` objects from a `NEPacketTunnelProvider`.
public final class NEInterfaceFactory: NetworkInterfaceFactory {
    public struct Options: Sendable {
        public var maxUDPDatagrams = 200

        public var minTCPLength = 2

        public var maxTCPLength = 512 * 1024

        public init() {
        }
    }

    private let ctx: PartoutLoggerContext

    private weak var provider: NEPacketTunnelProvider?

    private let options: Options

    public init(_ ctx: PartoutLoggerContext, provider: NEPacketTunnelProvider?, options: Options) {
        precondition(provider != nil) // weak
        self.ctx = ctx
        self.provider = provider
        self.options = options
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) -> LinkObserver? {
        guard let provider else {
            logReleasedProvider()
            return nil
        }
        let nwEndpoint = endpoint.nwEndpoint
        switch endpoint.proto.socketType.plainType {
        case .udp:
            let impl = provider.createUDPSession(to: nwEndpoint, from: nil)
            return NEUDPObserver(
                ctx,
                nwSession: impl,
                options: .init(
                    maxDatagrams: options.maxUDPDatagrams
                )
            )

        case .tcp:
            let impl = provider.createTCPConnection(to: nwEndpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
            return NETCPObserver(
                ctx,
                nwConnection: impl,
                options: .init(
                    minLength: options.minTCPLength,
                    maxLength: options.maxTCPLength
                )
            )
        }
    }

    public func tunnelInterface() -> TunnelInterface? {
        guard let provider else {
            logReleasedProvider()
            return nil
        }
        return NETunnelInterface(ctx, impl: provider.packetFlow)
    }
}

private extension NEInterfaceFactory {
    func logReleasedProvider() {
        pp_log(ctx, .ne, .info, "NEInterfaceFactory: NEPacketTunnelProvider released")
    }
}

private extension ExtendedEndpoint {
    var nwEndpoint: NWHostEndpoint {
        NWHostEndpoint(hostname: address.rawValue, port: proto.port.description)
    }
}
