// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@preconcurrency import NetworkExtension

/// A factory that spawns link and tunnel interfaces from a `NEPacketTunnelProvider`.
public final class NEInterfaceFactory: NetworkInterfaceFactory {
    public struct Options: Sendable {
        // Enable to use NWConnection, NW* sockets were removed from NetworkExtension.
        public var usesNETCP = false
        public var usesNEUDP = false

        public var maxUDPDatagrams = 200

        public var minTCPLength = 2

        public var maxTCPLength = 512 * 1024

        public init() {
        }
    }

    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private weak var provider: NEPacketTunnelProvider?

    private let options: Options

    public init(_ ctx: PartoutLoggerContext, provider: NEPacketTunnelProvider?, options: Options) {
        precondition(provider != nil) // weak
        self.ctx = ctx
        self.provider = provider
        self.options = options
    }

    public func linkObserver(to endpoint: ExtendedEndpoint) throws -> LinkObserver {
        guard let provider else {
            pp_log(ctx, .os, .info, "NEInterfaceFactory: NEPacketTunnelProvider released")
            throw PartoutError(.releasedObject)
        }
        switch endpoint.proto.socketType.plainType {
        case .udp:
            if options.usesNEUDP {
                let impl = NWConnection(to: endpoint.nwEndpoint, using: .udp)
                let socketOptions = NESocketObserver.Options(
                    proto: .udp,
                    minLength: 0,   // unused
                    maxLength: 0    // unused
                )
                return NESocketObserver(ctx, nwConnection: impl, options: socketOptions)
            } else {
#if swift(>=6.0)
                fatalError("Must enable .usesNetworkFramework in Swift 6.0")
#else
                let impl = provider.createUDPSession(
                    to: endpoint.nwHostEndpoint,
                    from: nil
                )
                return NEUDPObserver(
                    ctx,
                    nwSession: impl,
                    options: .init(
                        maxDatagrams: options.maxUDPDatagrams
                    )
                )
#endif
            }

        case .tcp:
            if options.usesNETCP {
                let impl = NWConnection(to: endpoint.nwEndpoint, using: .tcp)
                let socketOptions = NESocketObserver.Options(
                    proto: .tcp,
                    minLength: options.minTCPLength,
                    maxLength: options.maxTCPLength
                )
                return NESocketObserver(ctx, nwConnection: impl, options: socketOptions)
            } else {
#if swift(>=6.0)
                fatalError("Must enable .usesNetworkFramework in Swift 6.0")
#else
                let impl = provider.createTCPConnection(
                    to: endpoint.nwHostEndpoint,
                    enableTLS: false,
                    tlsParameters: nil,
                    delegate: nil
                )
                return NETCPObserver(
                    ctx,
                    nwConnection: impl,
                    options: .init(
                        minLength: options.minTCPLength,
                        maxLength: options.maxTCPLength
                    )
                )
#endif
            }
        }
    }
}

private extension ExtendedEndpoint {
    var nwEndpoint: Network.NWEndpoint {
        .hostPort(host: .init(address.rawValue), port: .init(integerLiteral: proto.port))
    }

#if swift(<6.0)
    @available(*, deprecated, message: "NetworkExtension UDP/TCP sockets were removed in Swift 6")
    var nwHostEndpoint: NWHostEndpoint {
        NWHostEndpoint(hostname: address.rawValue, port: proto.port.description)
    }
#endif
}
