// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

/// A wrapper for a virtual tun device.
public final class TunWrapper: NativeIOInterface, @unchecked Sendable {
    private let ctx: PartoutLoggerContext
    private let tun: pp_tun
    private var isClosed = false

    // WARNING: Ownership of pp_tun handle is transferred!
    init(_ ctx: PartoutLoggerContext, tun: pp_tun) {
        self.ctx = ctx
        self.tun = tun
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit TunWrapper")
        cleanup()
    }

    public func setEventMask(read: Bool, write: Bool) throws {
    }

    public func resetEvents() throws {
    }

    public func read(_ buf: inout [UInt8]) -> Int32 {
        pp_tun_read(tun, &buf, buf.count)
    }

    public func write(_ data: Data, offset: Int) -> Int32 {
        let count = data.count - offset
        return data.withUnsafeBytes {
            pp_tun_write(
                tun,
                $0.bytePointer + offset,
                count
            )
        }
    }

    public func cleanup() {
        guard !isClosed else { return }
        isClosed = true
        pp_tun_free(tun)
    }

    public var lastErrorCode: Int32 {
        pp_io_last_error()
    }
}

extension TunWrapper: TunInterface {
    public var nativeIO: NativeIOInterface? {
        self
    }

    public var muxDescriptor: FileDescriptor? {
        let fd = pp_tun_get_watch_fd(tun)
        guard pp_fd_is_valid(fd) else { return nil }
        return fd
    }

    public func readPackets() async throws -> [Data] {
        fatalError("Not implemented")
    }

    public func writePackets(_ packets: [Data]) async throws {
        fatalError("Not implemented")
    }
}

#if canImport(Darwin)
extension TunWrapper {
    public static func forNetworkExtension(_ ctx: PartoutLoggerContext) throws -> TunWrapper {
        var tun: pp_tun?

        // Look up Network Extension fd first
        if let networkExtensionFd {
            tun = pp_tun_dup(networkExtensionFd)
        }
#if os(macOS)
        // Otherwise, open new device
        if tun == nil {
            let uuid = ctx.profileId ?? UUID()
            tun = uuid.uuidString.withCString {
                pp_tun_open($0)
            }
        }
#endif
        guard let tun else {
            throw PartoutError(.tunNotAvailable)
        }
        return TunWrapper(ctx, tun: tun)
    }

    // FIXME: ###, This is better done in C to also omit the manual structs from tun.h
    public static var networkExtensionFd: Int32? {
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

    private static let CTLIOCGINFO: UInt = 0xc0644e03
}
#endif
