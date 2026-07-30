// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import NetworkExtension

/// A tunnel interface based on `NEPacketTunnelFlow`.
public final class NETunnelInterface: TunInterface {
    private let ctx: PartoutLoggerContext

    nonisolated(unsafe)
    private weak var impl: NEPacketTunnelFlow?

    public init(_ ctx: PartoutLoggerContext, impl: NEPacketTunnelFlow) {
        self.ctx = ctx
        self.impl = impl
    }

    // MARK: TunInterface

    public var muxDescriptor: FileDescriptor? {
        NEPacketTunnelFlow.nativeFileDescriptor
    }

    public var nativeIO: NativeIOInterface? {
        do {
            return try NEPacketTunnelFlow.forNativeIO(ctx)
        } catch {
            pp_log(ctx, .os, .fault, "Unable to create or look up tun I/O interface: \(error)")
            return nil
        }
    }

    public func readPackets() async throws -> [Data] {
        guard let impl else {
            pp_log(ctx, .os, .error, "NEPacketTunnelFlow released prematurely")
            throw PartoutError(.unhandled)
        }
        let pair = await impl.readPackets()
        return pair.0
    }

    public func writePackets(_ packets: [Data]) {
        let protocols = packets.map(IPHeader.protocolNumber(inPacket:))
        impl?.writePackets(packets, withProtocols: protocols as [NSNumber])
    }
}
