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

extension TunWrapper: IOInterface {
    var fileDescriptor: FileDescriptor? {
#if os(Windows)
        nil
#else
        let fd = pp_tun_get_fd(tun)
        guard fd >= 0 else {
            assertionFailure("Invalid fd")
            return nil
        }
        return fd
#endif
    }

    func readPackets() async throws -> [Data] {
        fatalError("Not implemented")
    }

    func writePackets(_ packets: [Data]) async throws {
        fatalError("Not implemented")
    }
}
