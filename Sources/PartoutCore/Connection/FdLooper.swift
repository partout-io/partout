// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(Windows)
internal import _PartoutCore_C

public struct FdLooperDelegate: Sendable {
    public enum Side: Sendable {
        case link
        case tun
    }
    public typealias OnRead = @Sendable (_ packets: [Data], _ side: Side) -> Void
    public typealias OnFinish = @Sendable (_ error: Error?) -> Void

    public let onRead: OnRead
    public let onFinish: OnFinish

    public init(
        onRead: @escaping OnRead,
        onFinish: @escaping OnFinish
    ) {
        self.onRead = onRead
        self.onFinish = onFinish
    }
}

/// Loops through a set of file descriptors.
public final class FdLooper: @unchecked Sendable {
    private enum State: Sendable {
        case idle
        case started
        case stopping
        case stopped
    }

    fileprivate enum Command {
        case attachTun(tunInterface: IOInterface, CheckedContinuation<Void, Error>)
        case stop
    }

    private static let numberOfDescriptors = 2

    private let ctx: PartoutLoggerContext
    private let originalLink: IOInterface
    private var originalTun: IOInterface?
    private let mux: pp_mux
    private let linkFd: Int32
    private var tunFd: Int32?
    private let link: pp_socket
    private var tun: pp_tun?
    private let delegate: FdLooperDelegate
    private let maxReadSize: Int
    private let maxReadCount: Int

    private let loopQueue: DispatchQueue
    private let lock: SemaphoreMutex
    private var commands: [Command]
    private var state: State
    private var terminalError: Error?
    private var linkBuf: [UInt8]
    private var tunBuf: [UInt8]

    // Consumer:
    // - Writes to linkQueue/tunQueue .outbound
    // - Reads from linkQueue/tunQueue .inbound
    private var linkQueue: [Data]
    private var tunQueue: [Data]

    public init(
        _ ctx: PartoutLoggerContext,
        link linkInterface: IOInterface,
        tun tunInterface: IOInterface?,
        delegate: FdLooperDelegate,
        linkBufSize: Int = 64 * 1024,
        tunBufSize: Int = 16 * 1024,
        maxReadSize: Int = 256 * 1024,
        maxReadCount: Int = 128
    ) throws {
        let linkFd = linkInterface.fileDescriptor.map(Int32.init)
        let tunFd = tunInterface?.fileDescriptor.map(Int32.init)
        guard let linkFd else {
            pp_log(ctx, .core, .fault, "Missing link descriptor")
            throw PartoutError(.fdUnavailable)
        }
        guard tunInterface == nil || tunFd != nil else {
            pp_log(ctx, .core, .fault, "Missing tun descriptor")
            throw PartoutError(.fdUnavailable)
        }
        guard let newMux = pp_mux_create(Int32(Self.numberOfDescriptors)) else {
            pp_log(ctx, .core, .fault, "Unable to create mux")
            throw PartoutError(.muxFailure)
        }
        guard pp_mux_add(newMux, linkFd) else {
            pp_log(ctx, .core, .fault, "Unable to add linkFd")
            pp_mux_free(newMux)
            throw PartoutError(.muxFailure, linkFd)
        }
        if let tunFd {
            guard pp_mux_add(newMux, tunFd) else {
                pp_log(ctx, .core, .fault, "Unable to add tunFd")
                pp_mux_free(newMux)
                throw PartoutError(.muxFailure, tunFd)
            }
        }

        self.ctx = ctx
        mux = newMux
        originalLink = linkInterface
        originalTun = tunInterface
        self.linkFd = linkFd
        self.tunFd = tunFd
        self.delegate = delegate
        self.maxReadSize = max(maxReadSize, linkBufSize, tunBufSize)
        self.maxReadCount = maxReadCount

        loopQueue = DispatchQueue(label: "FdLooper")
        lock = SemaphoreMutex()
        commands = []
        state = .idle
        link = pp_socket_create(UInt64(linkFd))
        tun = tunFd.map(pp_tun_create)
        linkBuf = Array(repeating: 0, count: linkBufSize)
        tunBuf = Array(repeating: 0, count: tunBufSize)
        linkQueue = []
        tunQueue = []
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        precondition(state == .started, "Call await stop() before releasing InterfaceLooper")

        pp_log(ctx, .core, .debug, "Deinit InterfaceLooper")
        pp_socket_release(link)
        tun.map(pp_tun_release)
        pp_mux_free(mux)
    }

    public func attachTun(_ tunInterface: IOInterface) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.with {
                // Ignore command if not started or stopping
                guard [.idle, .stopping].contains(state) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                commands.append(.attachTun(tunInterface: tunInterface, continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        precondition(state == .idle, "Looper already started")

        // Event loop
        loopQueue.async { [weak self] in
            defer {
                pp_log(self?.ctx ?? .global, .core, .info, "Finish looper")
                self?.finish()
            }

            // Hold mux weakly
            guard let weakMux = self?.mux else { return }
            nonisolated(unsafe) let mux = weakMux

            // Bind I/O callbacks to fd set. Fd set is never mutated
            // concurrently, no locks are needed.
            let fdSet = FdSet(capacity: Self.numberOfDescriptors)
            let fdSetCtx = Unmanaged.passRetained(fdSet).toOpaque()
            pp_mux_set_on_readable(mux, { ctx, fd in
                let fdSet = Unmanaged<FdSet>.fromOpaque(ctx).takeUnretainedValue()
                fdSet.readable.insert(fd)
            }, fdSetCtx)
            pp_mux_set_on_writable(mux, { ctx, fd in
                let fdSet = Unmanaged<FdSet>.fromOpaque(ctx).takeUnretainedValue()
                fdSet.writable.insert(fd)
            }, fdSetCtx)

            // Remember to clean up on finish
            defer {
                Unmanaged<FdSet>.fromOpaque(fdSetCtx).release()
            }

            // Start loop
            pp_log(self?.ctx ?? .global, .core, .info, "Start looper")
            while true {
                // Reset readable fds before the wait
                fdSet.resetReadable()

                // Perform the blocking call
                guard pp_mux_wait(mux) >= 0 else { break }

                // Unwrap AFTER blocking call
                guard let self else { break }
                guard !Task.isCancelled else { break }

                // Handle commands on wake signal (true = continue)
                guard handleCommands() else { break }

                // Iterate through the fds
                do {
                    try process(mux: mux, fdSet: fdSet)
                } catch {
                    pp_log(ctx, .core, .error, "Unable to process: \(error)")
                    finish(throwing: error)
                    break
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .started else { return }
        state = .stopping
        commands.append(.stop)
        pp_mux_wake(mux)
    }
}

private extension FdLooper {
    enum CommandResult {
        case attachTun(CheckedContinuation<Void, Error>, Result<Void, Error>)
    }

    func handleCommands() -> Bool {
        lock.lock()
        let pendingCommands = commands
        commands.removeAll(keepingCapacity: true)

        var shouldStop = false
        var results: [CommandResult] = []
        for cmd in pendingCommands {
            switch cmd {
            case .attachTun(let tunInterface, let continuation):
                guard let fd = tunInterface.fileDescriptor.map(Int32.init) else {
                    results.append(.attachTun(continuation, .failure(PartoutError(.tunNotAvailable))))
                    break
                }
                // Cancel attach if stopping
                guard state != .stopping else {
                    results.append(.attachTun(continuation, .failure(CancellationError())))
                    break
                }
                // Can only attach once
                guard tunFd == nil else {
                    results.append(.attachTun(continuation, .failure(PartoutError(.operationCancelled))))
                    break
                }
                guard pp_mux_add(mux, fd) else {
                    pp_log(ctx, .core, .fault, "Unable to attach tun")
                    results.append(.attachTun(continuation, .failure(PartoutError(.muxFailure, fd))))
                    break
                }
                pp_log(ctx, .core, .info, "Attach tun (fd=\(fd))")
                originalTun = tunInterface
                tunFd = fd
                tun = pp_tun_create(fd)
                results.append(.attachTun(continuation, .success(())))
            case .stop:
                pp_log(ctx, .core, .info, "Stop looper")
                shouldStop = true
            }
        }
        lock.unlock()

        results.forEach {
            switch $0 {
            case .attachTun(let continuation, let result):
                continuation.resume(with: result)
            }
        }
        return !shouldStop
    }

    func process(mux: pp_mux, fdSet: FdSet) throws {
        // Write link
        if fdSet.writable.contains(linkFd) {
            var watchWrites = false
            while let packet = linkQueue.first {
                let packetCount = packet.count
                let count = packet.withUnsafeBytes {
                    pp_socket_write(link, $0.bytePointer, packetCount)
                }
                guard count != PP_SOCKET_WOULD_BLOCK else {
                    watchWrites = true
                    break
                }
                guard count >= 0 else {
                    throw PartoutError(.ioFailure)
                }
                // Dequeue, but reinsert remainder on partial write
                linkQueue.removeFirst()
                if count < packet.count {
                    let partialPacket = Data(packet[Int(count)...])
                    linkQueue.insert(partialPacket, at: 0)
                    watchWrites = true
                }
            }
            // Stop watching if no blocks
            pp_mux_set_write(mux, linkFd, watchWrites)
            if !watchWrites {
                fdSet.writable.remove(linkFd)
            }
        }

        // Write tun
        if let tunFd, let tun, fdSet.writable.contains(tunFd) {
            var watchWrites = false
            while let packet = tunQueue.first {
                let packetCount = packet.count
                let count = packet.withUnsafeBytes {
                    pp_tun_write(tun, $0.bytePointer, packetCount)
                }
                guard count != PP_TUN_WOULD_BLOCK else {
                    watchWrites = true
                    break
                }
                guard count >= 0 else {
                    throw PartoutError(.ioFailure)
                }
                // Dequeue, but reinsert remainder on partial write
                tunQueue.removeFirst()
                if count < packet.count {
                    let partialPacket = Data(packet[Int(count)...])
                    tunQueue.insert(partialPacket, at: 0)
                    watchWrites = true
                }
            }
            // Stop watching if no blocks
            pp_mux_set_write(mux, tunFd, watchWrites)
            if !watchWrites {
                fdSet.writable.remove(tunFd)
            }
        }

        // Read tun
        if let tunFd, let tun, fdSet.readable.contains(tunFd) {
            var inbox: [Data] = []
            var readCount = 0
            var readSize: Int32 = 0
            while readCount < maxReadCount, readSize < maxReadSize {
                let count = pp_tun_read(tun, &tunBuf, tunBuf.count)
                guard count != PP_TUN_WOULD_BLOCK else {
                    break
                }
                guard count >= 0 else {
                    throw PartoutError(.ioFailure)
                }
                if count > 0 {
                    let packet = Data(tunBuf[0..<Int(count)])
                    inbox.append(packet)
                }
                // Keep going
                readCount += 1
                readSize += count
            }
            delegate.onRead(inbox, .tun)
        }

        // Read link
        if fdSet.readable.contains(linkFd) {
            var inbox: [Data] = []
            var readCount = 0
            var readSize: Int32 = 0
            while readCount < maxReadCount, readSize < maxReadSize {
                let count = pp_socket_read(link, &linkBuf, linkBuf.count)
                guard count != PP_SOCKET_WOULD_BLOCK else {
                    break
                }
                guard count >= 0 else {
                    throw PartoutError(.ioFailure)
                }
                if count > 0 {
                    let packet = Data(linkBuf[0..<Int(count)])
                    inbox.append(packet)
                }
                // Keep going
                readCount += 1
                readSize += count
            }
            delegate.onRead(inbox, .link)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard terminalError == nil else { return }
        terminalError = error
        state = .stopped
    }
}

private final class FdSet {
    var readable: Set<Int32>
    var writable: Set<Int32>

    init(capacity: Int) {
        readable = Set(minimumCapacity: capacity)
        writable = Set(minimumCapacity: capacity)
    }

    func resetReadable() {
        readable.removeAll(keepingCapacity: true)
    }
}

#endif
