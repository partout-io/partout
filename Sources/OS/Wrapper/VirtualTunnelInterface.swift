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

    public init(
        _ ctx: PartoutLoggerContext,
        withPacketInformation: Bool,
        maxReadLength: Int
    ) throws {
        guard let tun = pp_tun_open() else {
            throw PartoutError(.linkNotActive)
        }
        self.ctx = ctx
        self.tun = tun
        deviceName = String(cString: pp_tun_name(tun))

        // Socket is not owned by POSIXBlockingSocket to prevent double free in deinit
        let sock = pp_tun_socket(tun)
        io = POSIXBlockingSocket(
            ctx,
            sock: sock,
            closesOnEmptyRead: true,
            maxReadLength: maxReadLength
        )

        // Assume that packets are prefixed with the IP header
        if withPacketInformation {
            readBlock = {
                try await $0.readPackets().map {
                    $0[4..<$0.count]
                }
            }
            writeBlock = {
                try await $0.writePackets($1.map {
                    // FIXME: #188, IPHeader.protocolNumber should be a fast C function
                    let packetFamily = IPHeader.protocolNumber(inPacket: $0)
                    var wrapped = Data(capacity: 4 + $0.count)
                    // FIXME: #188, is this necessary?
                    wrapped.append(packetFamily.bigEndian)
                    wrapped.append(contentsOf: $0)
                    return wrapped
                })
            }
        } else {
            readBlock = {
                try await $0.readPackets()
            }
            writeBlock = {
                try await $0.writePackets($1)
            }
        }
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
