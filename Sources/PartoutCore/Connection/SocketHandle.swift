// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

final class SocketHandle: @unchecked Sendable {
    nonisolated(unsafe)
    let sock: pp_socket

    private let lock: Mutex

    private var descriptor: UInt64?

    private var isShuttingDown: Bool

    private var isClosed: Bool

    init(sock: pp_socket) {
        self.sock = sock
        lock = Mutex()
        descriptor = pp_socket_fd(sock)
        isShuttingDown = false
        isClosed = false
    }

    var fileDescriptor: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShuttingDown || isClosed
    }

    func requestShutdown() {
        let shouldShutdown: Bool
        lock.lock()
        shouldShutdown = !isShuttingDown && !isClosed
        if shouldShutdown {
            isShuttingDown = true
            descriptor = nil
        }
        lock.unlock()
        guard shouldShutdown else { return }
        pp_socket_shutdown(sock)
    }

    func close() {
        let shouldClose: Bool
        lock.lock()
        shouldClose = !isClosed
        if shouldClose {
            isClosed = true
            descriptor = nil
        }
        lock.unlock()
        guard shouldClose else { return }
        pp_socket_close(sock)
    }

    deinit {
        pp_socket_free(sock)
    }
}
