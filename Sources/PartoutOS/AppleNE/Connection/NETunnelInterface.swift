// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C
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

    public var nativeIO: NativeIOInterface? {
        let fd = Self.existingFileDescriptor
        do {
            return try TunWrapper(ctx, fd: fd)
        } catch {
            pp_log(ctx, .os, .fault, "Unable to create or look up tun I/O interface: \(error)")
            return nil
        }
    }

    public var muxDescriptor: FileDescriptor? {
        Self.existingFileDescriptor
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

extension NETunnelInterface {
    private static let CTLIOCGINFO: UInt = 0xc0644e03

    // FIXME: ###, This is better done in C to also omit the manual structs from tun.h
    public static var existingFileDescriptor: Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            let ret = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getpeername(fd, $0, &len)
                }
            }
            guard ret == 0 && addr.sc_family == AF_SYSTEM else {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                let ret = ioctl(fd, Self.CTLIOCGINFO, &ctlInfo)
                guard ret == 0 else {
                    continue
                }
            }
            guard addr.sc_id == ctlInfo.ctl_id else {
                continue
            }
            return fd
        }
        return nil
    }
}
