// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if os(macOS) || os(Linux)

import Foundation
import _PartoutOSPortable_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

public actor VirtualTunnelInterface: IOInterface {
    private let ctx: PartoutLoggerContext

    private let tun: pp_tun

    public nonisolated let deviceName: String

    private let io: IOInterface

    private let readBlock: (IOInterface) async throws -> [Data]

    private let writeBlock: (IOInterface, [Data]) async throws -> Void

    public init(_ ctx: PartoutLoggerContext, maxReadLength: Int) throws {
        guard let tun = pp_tun_open() else {
            throw PartoutError(.linkNotActive)
        }
        self.ctx = ctx
        self.tun = tun
        deviceName = String(cString: pp_tun_name(tun))

        // Socket ownership is transferred to POSIXBlockingSocket
        let sock = pp_tun_socket(tun)
        io = POSIXBlockingSocket(
            ctx,
            sock: sock,
            closesOnEmptyRead: true,
            maxReadLength: maxReadLength
        )

#if os(macOS)
        // Mac packets are prefixed with the IP header
        readBlock = { io in
            try await io.readPackets().map {
                $0[4..<$0.count]
            }
        }
        writeBlock = { io, packets in
            try await io.writePackets(packets.map { packet in
                let family = IPHeader.protocolNumber(inPacket: packet)
                return withUnsafeBytes(of: family.bigEndian) { familyBytes in
                    var result = Data(count: familyBytes.count + packet.count)
                    result.withUnsafeMutableBytes { buffer in
                        buffer[..<familyBytes.count].copyBytes(from: familyBytes)
                        buffer[familyBytes.count...].copyBytes(from: packet)
                    }
                    return result
                }
            })
        }
#else
        // Raw IP packets (Linux requires IFF_NO_PI)
        readBlock = {
            try await $0.readPackets()
        }
        writeBlock = {
            try await $0.writePackets($1)
        }
#endif
    }

    deinit {
        pp_tun_free(tun)
    }

    public nonisolated var fileDescriptor: UInt64? {
        pp_socket_fd(pp_tun_socket(tun))
    }

    public func readPackets() async throws -> [Data] {
//        pp_log(ctx, .core, .fault, ">>> readPackets()")
        do {
            return try await readBlock(io)
        } catch {
            pp_log(ctx, .core, .fault, "Unable to read TUN packets: \(error)")
            throw error
        }
    }

    public func writePackets(_ packets: [Data]) async throws {
//        pp_log(ctx, .core, .fault, ">>> writePackets()")
        do {
            try await writeBlock(io, packets)
        } catch {
            pp_log(ctx, .core, .fault, "Unable to write TUN packets: \(error)")
            throw error
        }
    }
}

#endif
