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
}

extension TunWrapper: TunInterface {
    public var ioInterface: NativeIOInterface? {
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
