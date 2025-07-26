// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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
