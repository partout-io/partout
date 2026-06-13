// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

final class TunWrapper: NativeIOInterface, @unchecked Sendable {
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

    func setEventMask(read: Bool, write: Bool) throws {
    }

    func resetEvents() throws {
    }

    func read(_ buf: inout [UInt8]) throws -> Int? {
        let read = pp_tun_read(tun, &buf, buf.count)
        guard read != PPIOErrorWouldBlock else {
            throw NativeIOError.wouldBlock(.tun)
        }
        guard read >= 0 else {
            throw NativeIOError.libc(.tun, lastErrorCode)
        }
        guard read > 0 else {
            return nil
        }
        return Int(read)
    }

    func write(_ data: Data, offset: Int) throws -> Int {
        let writeCount = data.count - offset
        let written = data.withUnsafeBytes {
            pp_tun_write(
                tun,
                $0.bytePointer + offset,
                writeCount
            )
        }
        guard written != PPIOErrorWouldBlock else {
            throw NativeIOError.wouldBlock(.tun)
        }
        guard written != PPIOErrorNoBufs else {
            throw NativeIOError.noBufSpace(.tun)
        }
        guard written >= 0 else {
            throw NativeIOError.libc(.tun, lastErrorCode)
        }
        return Int(written)
    }

    func cleanup() {
        guard !isClosed else { return }
        isClosed = true
        pp_tun_free(tun)
    }

    var lastErrorCode: Int32 {
        pp_io_last_error()
    }
}

extension TunWrapper: TunInterface {
    var nativeIO: NativeIOInterface? {
        self
    }

    var muxDescriptor: FileDescriptor? {
        let fd = pp_tun_get_watch_fd(tun)
        guard pp_fd_is_valid(fd) else { return nil }
        return fd
    }

    func readPackets() async throws -> [Data] {
        fatalError("Not implemented")
    }

    func writePackets(_ packets: [Data]) async throws {
        fatalError("Not implemented")
    }
}

#if canImport(NetworkExtension)
import NetworkExtension

extension NEPacketTunnelFlow {
    public static func forNativeIO(_ ctx: PartoutLoggerContext) throws -> NativeIOInterface {
        guard let tun = pp_tun_lookup() else {
            throw PartoutError(.tunNotAvailable)
        }
        return TunWrapper(ctx, tun: tun)
    }
}
#endif
