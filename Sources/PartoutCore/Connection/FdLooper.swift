// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// FIXME: ###, Beware of the Int32/UInt64 mismatch (UNIX fd is Int32, Windows SOCKET is UInt64)

#if !os(Windows)
internal import _PartoutCore_C

/// Delegates ``FdLooper`` events.
public struct FdLooperDelegate: Sendable {
    public typealias OnRead = @Sendable (_ packets: [Data], _ side: FdLooper.Side) throws -> FdLooper.ReadAction
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
    public enum Side: Sendable {
        case link
        case tun
    }

    public enum ReadAction: Sendable {
        case keep
        case pause
    }

    private enum State: Sendable {
        case idle
        case started
        case stopping
        case stopped
    }

    fileprivate enum Command {
        case attachTun(tunInterface: IOInterface, CheckedContinuation<Void, Error>)
        case enableRead(Side)
        case enableWrite(Side)
        case stop
    }

    private static let numberOfDescriptors = 2

    private let ctx: PartoutLoggerContext
    private let mux: pp_mux
    private var link: SideIO
    private var tun: SideIO?
    private let linkHandle: pp_socket
    private var tunHandle: pp_tun?
    private let delegate: FdLooperDelegate
    private let tunBufSize: Int
    private let maxReadSize: Int
    private let maxReadCount: Int

    private let loopQueue: DispatchQueue
    private let lock: SemaphoreMutex
    private var commands: [Command]
    private var state: State
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var terminalError: Error?

    public init(
        _ ctx: PartoutLoggerContext,
        link linkInterface: IOInterface,
        delegate: FdLooperDelegate,
        linkBufSize: Int = 64 * 1024,
        tunBufSize: Int = 16 * 1024,
        maxReadSize: Int = 256 * 1024,
        maxReadCount: Int = 128
    ) throws {
        let linkFd = linkInterface.fileDescriptor.map(Int32.init)
        guard let linkFd else {
            pp_log(ctx, .core, .fault, "Missing link descriptor")
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

        self.ctx = ctx
        mux = newMux
        self.delegate = delegate
        self.tunBufSize = tunBufSize
        self.maxReadSize = max(maxReadSize, linkBufSize, tunBufSize)
        self.maxReadCount = maxReadCount

        loopQueue = DispatchQueue(label: "FdLooper")
        lock = SemaphoreMutex()
        commands = []
        state = .idle
        linkHandle = pp_socket_create(UInt64(linkFd))
        link = SideIO(
            linkFd: linkFd,
            handle: linkHandle,
            originalInterface: linkInterface,
            readBufSize: linkBufSize
        )
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            [.idle, .stopped].contains(state),
            "Called start() without stop() before releasing FdLooper"
        )

        pp_log(ctx, .core, .debug, "Deinit InterfaceLooper")
        tun?.cleanup()
        link.cleanup()
        pp_mux_free(mux)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        precondition(state == .idle, "Looper already started")

        // Event loop
        state = .started
        loopQueue.async { [weak self] in
            var lastError: Error?
            defer {
                self?.finish(throwing: lastError)
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
                    lastError = error
                    break
                }
            }
        }
    }

    public func stop() async throws {
        lock.lock()
        precondition(state == .started, "Cannot stop() twice")
        state = .stopping
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            commands.append(.stop)
            pp_mux_wake(mux)
            lock.unlock()
        }
    }

    public func attachTun(_ tunInterface: IOInterface) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.with {
                precondition(state == .started, "Attach tun after start()")
                commands.append(.attachTun(tunInterface: tunInterface, continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func resumeReading(from side: Side) {
        lock.lock()
        defer { lock.unlock() }
        commands.append(.enableRead(side))
        pp_mux_wake(mux)
    }

    public func write(_ packets: [Data], to side: Side) {
        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .link:
            packets.forEach {
                link.unsafeEnqueueWrite($0)
            }
            commands.append(.enableWrite(.link))
        case .tun:
            guard let tun else {
                pp_log(ctx, .core, .error, "Ignoring tun packets, not attached")
                return
            }
            packets.forEach {
                tun.unsafeEnqueueWrite($0)
            }
            commands.append(.enableWrite(.tun))
        }
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
                guard tun == nil else {
                    results.append(.attachTun(continuation, .failure(PartoutError(.operationCancelled))))
                    break
                }
                guard pp_mux_add(mux, fd) else {
                    pp_log(ctx, .core, .fault, "Unable to attach tun")
                    results.append(.attachTun(continuation, .failure(PartoutError(.muxFailure, fd))))
                    break
                }
                pp_log(ctx, .core, .info, "Attach tun (fd=\(fd))")

                // Create new side
                let tunHandle = pp_tun_create(fd)
                self.tunHandle = tunHandle
                tun = SideIO(
                    tunFd: fd,
                    handle: tunHandle,
                    originalInterface: tunInterface,
                    readBufSize: tunBufSize
                )

                results.append(.attachTun(continuation, .success(())))
            case .enableRead(let side):
                switch side {
                case .link:
                    pp_mux_set_read(mux, link.fd, true)
                case .tun:
                    if let tun {
                        pp_mux_set_read(mux, tun.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring tun enableRead(), not attached")
                    }
                }
            case .enableWrite(let side):
                switch side {
                case .link:
                    pp_mux_set_write(mux, link.fd, true)
                case .tun:
                    if let tun {
                        pp_mux_set_write(mux, tun.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring tun enableWrite(), not attached")
                    }
                }
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
        if fdSet.writable.contains(link.fd) {
            var watchWrites = false
            while let pending = link.dequeueWrite(lock: lock) {
                do {
                    let didComplete = try link.performWrite(pending, lock: lock)
                    watchWrites = !didComplete
                } catch IOError.wouldBlock {
                    watchWrites = true
                    break
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            // Stop watching if no blocks
            pp_mux_set_write(mux, link.fd, watchWrites)
            if !watchWrites {
                fdSet.writable.remove(link.fd)
            }
        }

        // Write tun
        if let tun, fdSet.writable.contains(tun.fd) {
            var watchWrites = false
            while let pending = tun.dequeueWrite(lock: lock) {
                do {
                    let didComplete = try tun.performWrite(pending, lock: lock)
                    watchWrites = !didComplete
                } catch IOError.wouldBlock {
                    watchWrites = true
                    break
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            // Stop watching if no blocks
            pp_mux_set_write(mux, tun.fd, watchWrites)
            if !watchWrites {
                fdSet.writable.remove(tun.fd)
            }
        }

        // Read tun
        if let tun, fdSet.readable.contains(tun.fd) {
            var inbox: [Data] = []
            var readCount = 0
            var readSize = 0
            while readCount < maxReadCount, readSize < maxReadSize {
                do {
                    if let packet = try tun.dequeueRead() {
                        inbox.append(packet)
                        readSize += packet.count
                    }
                    readCount += 1
                } catch IOError.wouldBlock {
                    break
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            if !inbox.isEmpty {
                let action = try delegate.onRead(inbox, .tun)
                if action == .pause {
                    pp_mux_set_read(mux, tun.fd, false)
                }
            }
        }

        // Read link
        if fdSet.readable.contains(link.fd) {
            var inbox: [Data] = []
            var readCount = 0
            var readSize = 0
            while readCount < maxReadCount, readSize < maxReadSize {
                do {
                    if let packet = try link.dequeueRead() {
                        inbox.append(packet)
                        readSize += packet.count
                    }
                    readCount += 1
                } catch IOError.wouldBlock {
                    break
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            if !inbox.isEmpty {
                let action = try delegate.onRead(inbox, .link)
                if action == .pause {
                    pp_mux_set_read(mux, link.fd, false)
                }
            }
        }
    }

    func finish(throwing error: Error? = nil) {
        if let error {
            pp_log(ctx, .core, .error, "Finish looper with error: \(error)")
        } else {
            pp_log(ctx, .core, .info, "Finish looper")
        }

        lock.lock()
        precondition(state != .stopped)
        state = .stopped
        terminalError = error
        lock.unlock()

        if let error {
            stopContinuation?.resume(throwing: error)
        } else {
            stopContinuation?.resume()
        }
        stopContinuation = nil
        delegate.onFinish(error)
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

// MARK: - SideIO

private extension FdLooper {
    enum IOError: Error {
        case wouldBlock
        case failed
    }

    struct PendingWrite {
        let data: Data
        let offset: Int
        init(_ data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }
        var count: Int {
            data.count - offset
        }
    }

    final class SideIO {
        let fd: Int32
        let originalInterface: IOInterface
        private let read: (inout [UInt8]) throws -> Data?
        private let write: (PendingWrite) throws -> Int
        let cleanup: () -> Void
        private var readBuf: [UInt8]
        private var writeQueue: RingQueue<Data>
        private var writeOffset: Int

        init(
            fd: Int32,
            originalInterface: IOInterface,
            readBufSize: Int,
            read: @escaping (inout [UInt8]) throws -> Data?,
            write: @escaping (PendingWrite) throws -> Int,
            cleanup: @escaping () -> Void
        ) {
            self.fd = fd
            self.originalInterface = originalInterface
            self.read = read
            self.write = write
            self.cleanup = cleanup
            readBuf = Array(repeating: 0, count: readBufSize)
            writeQueue = RingQueue()
            writeOffset = 0
        }

        func dequeueRead() throws -> Data? {
            try read(&readBuf)
        }

        func performWrite(_ pending: PendingWrite, lock: SemaphoreMutex) throws -> Bool {
            let count = try write(pending)
            let didComplete = count == pending.count
            lock.lock()
            if didComplete {
                writeQueue.removeFirst()
                writeOffset = 0
            } else {
                writeOffset += count
            }
            lock.unlock()
            return didComplete
        }

        func dequeueWrite(lock: SemaphoreMutex) -> PendingWrite? {
            lock.with {
                writeQueue.first.map {
                    PendingWrite($0, offset: writeOffset)
                }
            }
        }

        func unsafeEnqueueWrite(_ packet: Data) {
            writeQueue.append(packet)
        }
    }
}

// MARK: - Link/Tun initializers

private extension FdLooper.SideIO {
    convenience init(
        linkFd: Int32,
        handle: pp_socket,
        originalInterface: IOInterface,
        readBufSize: Int
    ) {
        nonisolated(unsafe) let linkHandle = handle
        self.init(
            fd: linkFd,
            originalInterface: originalInterface,
            readBufSize: readBufSize,
            read: { buf in
                let count = pp_socket_read(linkHandle, &buf, buf.count)
                guard count != PP_SOCKET_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.failed
                }
                guard count > 0 else {
                    return nil
                }
                return Data(buf[0..<Int(count)])
            },
            write: { pending in
                let count = pending.data.withUnsafeBytes {
                    pp_socket_write(
                        linkHandle,
                        $0.bytePointer + pending.offset,
                        pending.count
                    )
                }
                guard count != PP_SOCKET_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.failed
                }
                return Int(count)
            },
            cleanup: {
                pp_socket_release(linkHandle)
            }
        )
    }

    convenience init(
        tunFd: Int32,
        handle: pp_tun,
        originalInterface: IOInterface,
        readBufSize: Int
    ) {
        nonisolated(unsafe) let tunHandle = handle
        self.init(
            fd: tunFd,
            originalInterface: originalInterface,
            readBufSize: readBufSize,
            read: { buf in
                let count = pp_tun_read(tunHandle, &buf, buf.count)
                guard count != PP_TUN_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.failed
                }
                guard count > 0 else {
                    return nil
                }
                return Data(buf[0..<Int(count)])
            },
            write: { pending in
                let count = pending.data.withUnsafeBytes {
                    pp_tun_write(
                        tunHandle,
                        $0.bytePointer + pending.offset,
                        pending.count
                    )
                }
                guard count != PP_TUN_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.failed
                }
                return Int(count)
            },
            cleanup: {
                pp_tun_release(tunHandle)
            }
        )
    }
}

#endif
