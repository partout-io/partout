// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

final class TunWrapper: @unchecked Sendable {
    private let ctx: PartoutLoggerContext
    let tun: pp_tun

    // WARNING: Handle ownership is transferred
    init(_ ctx: PartoutLoggerContext, tun: pp_tun) {
        self.ctx = ctx
        self.tun = tun
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit TunWrapper")
        pp_tun_free(tun)
    }

    func close() {
        pp_tun_close(tun)
    }
}

extension TunWrapper: TunInterface {
    var ioDescriptor: Any? {
        tun
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
