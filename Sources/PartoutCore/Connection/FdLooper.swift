// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// FIXME: ###, Beware of the Int32/UInt64 mismatch (UNIX fd is Int32, Windows SOCKET is UInt64)

#if !os(Windows)
internal import _PartoutCore_C

/// Delegates ``FdLooper`` events.
public struct FdLooperDelegate: Sendable {
    public typealias OnRead = @Sendable (_ packets: [Data], _ side: FdLooper.Side) throws -> FdLooper.ReadAction
    public typealias OnWrite = @Sendable (_ packet: Data, _ side: FdLooper.Side) throws -> Data
    public typealias OnFinish = @Sendable (_ error: Error?) -> Void

    public let onRead: OnRead
    public let onWrite: OnWrite?
    public let onFinish: OnFinish

    public init(
        onRead: @escaping OnRead,
        onWrite: OnWrite?,
        onFinish: @escaping OnFinish
    ) {
        self.onRead = onRead
        self.onWrite = onWrite
        self.onFinish = onFinish
    }
}

/// Loops through a set of file descriptors.
public final class FdLooper: @unchecked Sendable {
    public enum Side: Hashable, Sendable {
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
        case attachLink(IOInterface, CheckedContinuation<Void, Error>)
        case attachTun(IOInterface, CheckedContinuation<Void, Error>)
        case detachLink(CheckedContinuation<Void, Never>)
        case detachTun(CheckedContinuation<Void, Never>)
        case enableRead(Side, UUID?)
        case enableWrite(Side, UUID?)
        case custom(@Sendable () throws -> Void)
        case stop
    }

    private static let numberOfDescriptors = 2

    private let ctx: PartoutLoggerContext
    private let mux: pp_mux
    private var link: SideIO?
    private var tun: SideIO?
    private var linkHandle: pp_socket?
    private var tunHandle: pp_tun?
    private let delegate: FdLooperDelegate
    private let linkBufSize: Int
    private let tunBufSize: Int
    private let maxReadSize: Int
    private let maxReadCount: Int
    private static let noBufRetryDelay: DispatchTimeInterval = .milliseconds(10)

    private let loopQueue: DispatchQueue
    private let loopQueueKey: DispatchSpecificKey<Void>
    private let retryQueue: DispatchQueue
    private let lock: SemaphoreMutex
    private var commands: [Command]
    private var readRetries: Set<Side>
    private var writeRetries: Set<Side>
    private var state: State
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var terminalError: Error?

    public init(
        _ ctx: PartoutLoggerContext,
        queue: DispatchQueue,
        delegate: FdLooperDelegate,
        linkBufSize: Int = 64 * 1024,
        tunBufSize: Int = 16 * 1024,
        maxReadSize: Int = 256 * 1024,
        maxReadCount: Int = 128
    ) throws {
        guard let newMux = pp_mux_create(Int32(Self.numberOfDescriptors)) else {
            pp_log(ctx, .core, .fault, "Unable to create mux")
            throw PartoutError(.muxFailure)
        }

        self.ctx = ctx
        mux = newMux
        self.delegate = delegate
        self.linkBufSize = linkBufSize
        self.tunBufSize = tunBufSize
        self.maxReadSize = max(maxReadSize, linkBufSize, tunBufSize)
        self.maxReadCount = maxReadCount

        loopQueue = queue
        loopQueueKey = DispatchSpecificKey()
        loopQueue.setSpecific(key: loopQueueKey, value: ())
        retryQueue = DispatchQueue(label: "\(queue.label).retry")
        lock = SemaphoreMutex()
        commands = []
        readRetries = []
        writeRetries = []
        state = .idle
    }

    deinit {
        pp_log(ctx, .core, .debug, "Deinit FdLooper")
        link?.detach()
        tun?.detach()
        stopWithoutWaiting()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        precondition(state == .idle, "Looper already started")

        // Hold mux for cleanup
        nonisolated(unsafe) let mux = self.mux

        // Event loop
        state = .started
        loopQueue.async { [weak self] in
            var lastError: Error?
            defer {
                self?.finish(throwing: lastError)
                self?.link?.detach()
                self?.tun?.detach()
                pp_mux_free(mux)
            }

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

                do {
                    // Handle commands on wake signal (true = continue)
                    guard try handleCommands() else { break }

                    // Iterate through the fds
                    try process(mux: mux, fdSet: fdSet)
                } catch IOError.linkFailed {
                    lock.with {
                        self.link?.detach()
                        self.link = nil
                    }
                } catch IOError.tunFailed {
                    lock.with {
                        self.tun?.detach()
                        self.tun = nil
                    }
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
        guard state != .idle else { return }
        precondition(state == .started, "Cannot stop() twice")
        state = .stopping
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            commands.append(.stop)
            pp_mux_wake(mux)
            lock.unlock()
        }
    }

    private func stopWithoutWaiting() {
        lock.lock()
        switch state {
        case .idle:
            pp_mux_free(mux)
        case .started:
            state = .stopping
            commands.append(.stop)
            pp_mux_wake(mux)
        default:
            break
        }
        lock.unlock()
    }

    public var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: loopQueueKey) != nil
    }

    public func perform<R>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
        if isOnQueue {
            return try body()
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.with {
                precondition(state == .started, "Perform after start()")
                commands.append(.custom {
                    do {
                        continuation.resume(returning: try body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                })
                pp_mux_wake(mux)
            }
        }
    }

    public func schedule(_ body: @escaping @Sendable () throws -> Void) rethrows {
        if isOnQueue {
            try body()
            return
        }
        lock.with {
            precondition(state == .started, "Schedule after start()")
            commands.append(.custom(body))
            pp_mux_wake(mux)
        }
    }

    public func attachLink(_ linkInterface: IOInterface) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.with {
                precondition(state == .started, "Attach link after start()")
                commands.append(.attachLink(linkInterface, continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func attachTun(_ tunInterface: IOInterface) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.with {
                precondition(state == .started, "Attach tun after start()")
                commands.append(.attachTun(tunInterface, continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func detachLink() async {
        await withCheckedContinuation { continuation in
            lock.with {
                precondition(state == .started, "Detach link after start()")
                commands.append(.detachLink(continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func detachTun() async {
        await withCheckedContinuation { continuation in
            lock.with {
                precondition(state == .started, "Detach link after start()")
                commands.append(.detachTun(continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public var isLinkAttached: Bool {
        lock.with {
            link != nil
        }
    }

    public var isTunAttached: Bool {
        lock.with {
            tun != nil
        }
    }

    public func resumeReading(from side: Side) {
        lock.lock()
        defer { lock.unlock() }
        commands.append(.enableRead(side, nil))
        pp_mux_wake(mux)
    }

    public func write(_ packets: [Data], to side: Side) throws {
        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .link:
            guard let link else {
                pp_log(ctx, .core, .error, "Ignoring link packets, not attached")
                return
            }
            try packets.forEach {
                let packet = try delegate.onWrite?($0, side) ?? $0
                link.unsafeEnqueueWrite(packet)
            }
            commands.append(.enableWrite(.link, nil))
        case .tun:
            guard let tun else {
                pp_log(ctx, .core, .error, "Ignoring tun packets, not attached")
                return
            }
            packets.forEach {
                tun.unsafeEnqueueWrite($0)
            }
            commands.append(.enableWrite(.tun, nil))
        }
        pp_mux_wake(mux)
    }
}

private extension FdLooper {
    enum CommandResult {
        case attach(CheckedContinuation<Void, Error>, Result<Void, Error>)
        case detach(CheckedContinuation<Void, Never>)
    }

    func handleCommands() throws -> Bool {
        lock.lock()
        let pendingCommands = commands
        commands.removeAll(keepingCapacity: true)

        var shouldStop = false
        var results: [CommandResult] = []
        for cmd in pendingCommands {
            switch cmd {
            case .attachLink(let linkInterface, let continuation):
                guard let fd = linkInterface.fileDescriptor else {
                    results.append(.attach(continuation, .failure(PartoutError(.fdUnavailable))))
                    break
                }
                // Cancel attach if stopping
                guard state != .stopping else {
                    results.append(.attach(continuation, .failure(CancellationError())))
                    break
                }
                // Can only attach once
                guard link == nil else {
                    results.append(.attach(continuation, .failure(PartoutError(.operationCancelled))))
                    break
                }
                let linkFd = Int32(fd)
                guard pp_mux_add(mux, linkFd) else {
                    pp_log(ctx, .core, .fault, "Unable to attach link")
                    results.append(.attach(continuation, .failure(PartoutError(.muxFailure, fd))))
                    break
                }
                pp_log(ctx, .core, .info, "Attach link (fd=\(fd))")

                // Create new side
                let linkHandle = pp_socket_create(fd)
                self.linkHandle = linkHandle
                link = SideIO(
                    mux: mux,
                    linkFd: linkFd,
                    handle: linkHandle,
                    originalInterface: linkInterface,
                    readBufSize: linkBufSize
                )
                results.append(.attach(continuation, .success(())))
            case .attachTun(let tunInterface, let continuation):
                guard let fd = tunInterface.fileDescriptor else {
                    results.append(.attach(continuation, .failure(PartoutError(.fdUnavailable))))
                    break
                }
                // Cancel attach if stopping
                guard state != .stopping else {
                    results.append(.attach(continuation, .failure(CancellationError())))
                    break
                }
                // Can only attach once
                guard tun == nil else {
                    results.append(.attach(continuation, .failure(PartoutError(.operationCancelled))))
                    break
                }
                let tunFd = Int32(fd)
                guard pp_mux_add(mux, tunFd) else {
                    pp_log(ctx, .core, .fault, "Unable to attach tun")
                    results.append(.attach(continuation, .failure(PartoutError(.muxFailure, fd))))
                    break
                }
                pp_log(ctx, .core, .info, "Attach tun (fd=\(fd))")

                // Create new side
                let tunHandle = pp_tun_create(tunFd)
                self.tunHandle = tunHandle
                tun = SideIO(
                    mux: mux,
                    tunFd: tunFd,
                    handle: tunHandle,
                    originalInterface: tunInterface,
                    readBufSize: tunBufSize
                )
                results.append(.attach(continuation, .success(())))
            case .detachLink(let continuation):
                link?.detach()
                link = nil
                readRetries.remove(.link)
                writeRetries.remove(.link)
                results.append(.detach(continuation))
            case .detachTun(let continuation):
                tun?.detach()
                tun = nil
                readRetries.remove(.tun)
                writeRetries.remove(.tun)
                results.append(.detach(continuation))
            case .enableRead(let side, let id):
                if let id {
                    guard !isOutdated(id, side: side) else {
                        break
                    }
                }
                switch side {
                case .link:
                    if let link {
                        pp_mux_set_read(mux, link.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring link enableRead(), not attached")
                    }
                case .tun:
                    if let tun {
                        pp_mux_set_read(mux, tun.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring tun enableRead(), not attached")
                    }
                }
            case .enableWrite(let side, let id):
                if let id {
                    guard !isOutdated(id, side: side) else {
                        break
                    }
                }
                switch side {
                case .link:
                    if let link {
                        pp_mux_set_write(mux, link.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring link enableWrite(), not attached")
                    }
                case .tun:
                    if let tun {
                        pp_mux_set_write(mux, tun.fd, true)
                    } else {
                        pp_log(ctx, .core, .error, "Ignoring tun enableWrite(), not attached")
                    }
                }
            case .custom(let body):
                lock.unlock()
                try body()
                lock.lock()
            case .stop:
                pp_log(ctx, .core, .info, "Stop looper")
                shouldStop = true
            }
        }
        lock.unlock()

        results.forEach {
            switch $0 {
            case .attach(let continuation, let result):
                continuation.resume(with: result)
            case .detach(let continuation):
                continuation.resume()
            }
        }
        return !shouldStop
    }

    func process(mux: pp_mux, fdSet: FdSet) throws {
        // Write link
        if let link, fdSet.writable.contains(link.fd) {
            var watchWrites = false
            while let pending = link.dequeueWrite(lock: lock) {
                do {
                    let didComplete = try link.performWrite(pending, lock: lock)
                    watchWrites = !didComplete
                } catch IOError.wouldBlock {
                    watchWrites = true
                    break
                } catch IOError.noBufSpace {
                    if let tun {
                        suspendReadAndScheduleRetry(from: tun, fdSet: fdSet)
                    }
                    scheduleWriteRetry(to: link)
                    watchWrites = false
                    break
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
                } catch IOError.noBufSpace {
                    if let link {
                        suspendReadAndScheduleRetry(from: link, fdSet: fdSet)
                    }
                    scheduleWriteRetry(to: tun)
                    watchWrites = false
                    break
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
        if let link, fdSet.readable.contains(link.fd) {
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

    func suspendReadAndScheduleRetry(from io: SideIO, fdSet: FdSet) {
        pp_mux_set_read(mux, io.fd, false)
        fdSet.readable.remove(io.fd)

        lock.lock()
        guard state == .started, !readRetries.contains(io.side) else {
            lock.unlock()
            return
        }
        readRetries.insert(io.side)
        lock.unlock()

        let side = io.side
        let command: Command = .enableRead(side, io.id)
        retryQueue.asyncAfter(deadline: .now() + Self.noBufRetryDelay) { [weak self] in
            guard let self else { return }
            self.lock.with {
                self.readRetries.remove(side)
                guard self.state == .started else {
                    return
                }
                self.commands.append(command)
                pp_mux_wake(self.mux)
            }
        }
    }

    func scheduleWriteRetry(to io: SideIO) {
        lock.lock()
        guard state == .started, !writeRetries.contains(io.side) else {
            lock.unlock()
            return
        }
        writeRetries.insert(io.side)
        lock.unlock()

        let side = io.side
        let command: Command = .enableWrite(side, io.id)
        retryQueue.asyncAfter(deadline: .now() + Self.noBufRetryDelay) { [weak self] in
            guard let self else { return }
            self.lock.with {
                self.writeRetries.remove(side)
                guard self.state == .started else {
                    return
                }
                self.commands.append(command)
                pp_mux_wake(self.mux)
            }
        }
    }

    func isOutdated(_ id: UUID, side: Side) -> Bool {
        switch side {
        case .link:
            return id != link?.id
        case .tun:
            return id != tun?.id
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
        case noBufSpace
        case linkFailed
        case tunFailed
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

    final class SideIO: Identifiable {
        let id = UUID()
        let side: Side
        let fd: Int32
        let originalInterface: IOInterface
        private let read: (inout [UInt8]) throws -> Data?
        private let write: (PendingWrite) throws -> Int
        private var cleanup: (() -> Void)?
        private var readBuf: [UInt8]
        private var writeQueue: RingQueue<Data>
        private var writeOffset: Int

        init(
            side: Side,
            fd: Int32,
            originalInterface: IOInterface,
            readBufSize: Int,
            read: @escaping (inout [UInt8]) throws -> Data?,
            write: @escaping (PendingWrite) throws -> Int,
            cleanup: @escaping () -> Void
        ) {
            self.side = side
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

        func detach() {
            cleanup?()
            cleanup = nil
        }
    }
}

// MARK: - Link/Tun initializers

private extension FdLooper.SideIO {
    convenience init(
        mux: pp_mux,
        linkFd: Int32,
        handle: pp_socket,
        originalInterface: IOInterface,
        readBufSize: Int
    ) {
        nonisolated(unsafe) let linkHandle = handle
        self.init(
            side: .link,
            fd: linkFd,
            originalInterface: originalInterface,
            readBufSize: readBufSize,
            read: { buf in
                let count = pp_socket_read(linkHandle, &buf, buf.count)
                guard count != PP_SOCKET_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.linkFailed
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
                guard count != PP_SOCKET_NO_BUF else {
                    throw FdLooper.IOError.noBufSpace
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.linkFailed
                }
                return Int(count)
            },
            cleanup: {
                pp_mux_delete(mux, linkFd)
                pp_socket_release(linkHandle)
            }
        )
    }

    convenience init(
        mux: pp_mux,
        tunFd: Int32,
        handle: pp_tun,
        originalInterface: IOInterface,
        readBufSize: Int
    ) {
        nonisolated(unsafe) let tunHandle = handle
        self.init(
            side: .tun,
            fd: tunFd,
            originalInterface: originalInterface,
            readBufSize: readBufSize,
            read: { buf in
                let count = pp_tun_read(tunHandle, &buf, buf.count)
                guard count != PP_TUN_WOULD_BLOCK else {
                    throw FdLooper.IOError.wouldBlock
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.tunFailed
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
                guard count != PP_TUN_NO_BUF else {
                    throw FdLooper.IOError.noBufSpace
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.tunFailed
                }
                return Int(count)
            },
            cleanup: {
                pp_mux_delete(mux, tunFd)
                pp_tun_release(tunHandle)
            }
        )
    }
}

#endif
