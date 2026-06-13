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

    public func read(_ buf: inout [UInt8]) throws -> Int {
        let read = pp_tun_read(tun, &buf, buf.count)
        guard read != PPIOErrorWouldBlock else {
            throw NativeIOError.wouldBlock(.tun)
        }
        guard read >= 0 else {
            throw NativeIOError.libc(.tun, lastErrorCode)
        }
        return Int(read)
    }

    public func write(_ data: Data, offset: Int) throws -> Int {
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
        // Look up Network Extension fd first
        var tun = pp_tun_lookup()
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
}
#endif
