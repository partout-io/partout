// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

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

    public typealias TransformWrite = @Sendable (_ packets: [Data]) throws -> [Data]
    public typealias OnRead = @Sendable (_ packets: [Data]) throws -> FdLooper.ReadAction
    public typealias OnFailure = @Sendable (_ error: Error) -> Void
    public typealias OnFinish = @Sendable (_ error: Error?) -> Void

    public struct AttachArguments: Sendable {
        public enum DescriptorPair: @unchecked Sendable {
            case link(FileDescriptor, NativeIOInterface)
            case tun(FileDescriptor, NativeIOInterface)
        }

        public let pair: DescriptorPair
        public let closesOnEmptyRead: Bool
        public let transformWrite: TransformWrite?
        public let onRead: OnRead?
        public let onFailure: OnFailure?

        public init(
            pair: DescriptorPair,
            closesOnEmptyRead: Bool,
            transformWrite: TransformWrite?,
            onRead: OnRead?,
            onFailure: OnFailure?
        ) {
            self.pair = pair
            self.closesOnEmptyRead = closesOnEmptyRead
            self.transformWrite = transformWrite
            self.onRead = onRead
            self.onFailure = onFailure
        }
    }

    private static let numberOfDescriptors = 2
    private static let noBufRetryDelay: DispatchTimeInterval = .milliseconds(10)

    private let ctx: PartoutLoggerContext
    private let mux: pp_mux
    private let linkBufSize: Int
    private let tunBufSize: Int
    private let maxReadSize: Int
    private let maxReadCount: Int
    private let onFinish: OnFinish

    private let loopQueue: DispatchQueue
    private let loopQueueKey: DispatchSpecificKey<Void>
    private let scheduleQueue: DispatchQueue
    private let lock: SemaphoreMutex

    private var state: State
    private var commands: [Command]
    private var readRetries: Set<Side>
    private var writeRetries: Set<Side>
    private var link: SideIO?
    private var tun: SideIO?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var terminalError: Error?

    public init(
        _ ctx: PartoutLoggerContext,
        queue: DispatchQueue,
        linkBufSize: Int = 64 * 1024,
        tunBufSize: Int = 16 * 1024,
        maxReadSize: Int = 256 * 1024,
        maxReadCount: Int = 128,
        onFinish: @escaping OnFinish
    ) throws {
        guard let newMux = pp_mux_create(Int32(Self.numberOfDescriptors)) else {
            pp_log(ctx, .core, .fault, "Unable to create mux")
            throw MuxError(side: nil)
        }

        self.ctx = ctx
        mux = newMux
        self.linkBufSize = linkBufSize
        self.tunBufSize = tunBufSize
        self.maxReadSize = max(maxReadSize, linkBufSize, tunBufSize)
        self.maxReadCount = maxReadCount
        self.onFinish = onFinish

        loopQueue = queue
        loopQueueKey = DispatchSpecificKey()
        loopQueue.setSpecific(key: loopQueueKey, value: ())
        scheduleQueue = DispatchQueue(label: "\(queue.label).schedule")
        lock = SemaphoreMutex()

        state = .idle
        commands = []
        readRetries = []
        writeRetries = []
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
        guard state == .idle else {
            assertionFailure("Looper already started")
            return
        }

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
            let ctx = self?.ctx ?? .global
            pp_log(ctx, .core, .info, "Start looper")
            while true {
                // Reset readable fds before the wait
                fdSet.resetReadable()

                // Perform the blocking call
                var code: Int32 = 0
                guard pp_mux_wait(mux, &code) >= 0 else {
                    pp_log(ctx, .core, .fault, "Looper: pp_mux_wait() failed (code=\(code))")
                    lastError = WaitError(code: code)
                    break
                }

                // Unwrap AFTER blocking call
                guard let self else {
                    pp_log(ctx, .core, .info, "Looper: released self")
                    break
                }

                do {
                    // Handle commands on wake signal (true = continue)
                    guard try handleCommands(fdSet: fdSet) else {
                        pp_log(.global, .core, .info, "Looper: stop requested")
                        break
                    }

                    // Iterate through the fds
                    try process(mux: mux, fdSet: fdSet)
                } catch IOError.user(let side, let reason) {
                    // Unwrap user-defined errors
                    detachImmediately(side, withReason: reason)
                } catch let reason as IOError {
                    // Rethrow any other IOError as is
                    detachImmediately(reason.side, withReason: reason)
                } catch {
                    pp_log(ctx, .core, .fault, "Unable to process: \(error)")
                    lastError = error
                    break
                }
            }
        }
    }

    public func stop() async throws {
        lock.lock()
        guard state != .idle else {
            // Never started
            lock.unlock()
            return
        }
        guard state == .started else {
            lock.unlock()
            assertionFailure("Stopping twice?")
            return
        }
        state = .stopping
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            commands.append(.stop)
            pp_mux_wake(mux)
            lock.unlock()
        }
    }

    private func stopWithoutWaiting() {
        lock.with {
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
        }
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
                guard state == .started else {
                    pp_log(ctx, .core, .error, "Ignoring perform before start()")
                    continuation.resume(throwing: CancellationError())
                    return
                }
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

    public func schedule(
        after delay: DispatchTimeInterval? = nil,
        _ body: @escaping @Sendable () throws -> Void
    ) rethrows {
        guard let delay else {
            if isOnQueue {
                try body()
            } else {
                lock.with {
                    guard state == .started else {
                        pp_log(ctx, .core, .error, "Ignoring schedule before start()")
                        return
                    }
                    commands.append(.custom(body))
                    pp_mux_wake(mux)
                }
            }
            return
        }
        scheduleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.with {
                guard self.state == .started else {
                    return
                }
                self.commands.append(.custom(body))
                pp_mux_wake(self.mux)
            }
        }
    }

    // WARNING: link/tun ownership is transferred after a successful attach!
    public func attach(_ arguments: AttachArguments) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.with {
                guard state == .started else {
                    pp_log(ctx, .core, .error, "Ignoring attach before start()")
                    continuation.resume()
                    assertionFailure("Attach after start()")
                    return
                }
                commands.append(.attach(arguments, continuation))
                pp_mux_wake(mux)
            }
        }
    }

    public func detach(_ side: Side) async {
        await withCheckedContinuation { continuation in
            lock.with {
                guard state == .started else {
                    pp_log(ctx, .core, .error, "Ignoring detach before start()")
                    continuation.resume()
                    assertionFailure("Detach after start()")
                    return
                }
                commands.append(.detach(side, continuation))
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

    public func write(_ packets: [Data], to side: Side, outOfBand: Bool = false) throws {
        if outOfBand {
            guard isOnQueue else {
                pp_log(ctx, .core, .fault, "OOB writes must run on the looper queue")
                return
            }
            switch side {
            case .link:
                guard let link else {
                    pp_log(ctx, .core, .error, "Ignoring link packets, not attached")
                    return
                }
                let processedPackets = try link.transformWrite?(packets) ?? packets
                try processedPackets.forEach(link.writeOutOfBand)
            case .tun:
                guard let tun else {
                    pp_log(ctx, .core, .error, "Ignoring tun packets, not attached")
                    return
                }
                let processedPackets = try tun.transformWrite?(packets) ?? packets
                try processedPackets.forEach(tun.writeOutOfBand)
            }
            return
        }

        lock.lock()
        defer { lock.unlock() }
        switch side {
        case .link:
            guard let link else {
                pp_log(ctx, .core, .error, "Ignoring link packets, not attached")
                return
            }
            lock.unlock()

            let processedPackets = try link.transformWrite?(packets) ?? packets

            lock.lock()
            guard link === self.link else {
                pp_log(ctx, .core, .error, "Ignoring detached link during processing")
                return
            }
            processedPackets.forEach {
                link.unsafeEnqueueWrite($0)
            }
            commands.append(.enableWrite(.link, nil))
        case .tun:
            guard let tun else {
                pp_log(ctx, .core, .error, "Ignoring tun packets, not attached")
                return
            }
            lock.unlock()

            let processedPackets = try tun.transformWrite?(packets) ?? packets

            lock.lock()
            guard tun === self.tun else {
                pp_log(ctx, .core, .error, "Ignoring detached tun during processing")
                return
            }
            processedPackets.forEach {
                tun.unsafeEnqueueWrite($0)
            }
            commands.append(.enableWrite(.tun, nil))
        }
        pp_mux_wake(mux)
    }
}

private extension FdLooper {
    enum State: Sendable {
        case idle
        case started
        case stopping
        case stopped
    }

    enum Command {
        case attach(AttachArguments, CheckedContinuation<Void, Error>)
        case detach(Side, CheckedContinuation<Void, Never>)
        case enableRead(Side, UUID?)
        case enableWrite(Side, UUID?)
        case custom(@Sendable () throws -> Void)
        case stop
    }

    enum CommandResult {
        case attach(CheckedContinuation<Void, Error>, Result<Void, Error>)
        case detach(CheckedContinuation<Void, Never>)
    }

    func handleCommands(fdSet: FdSet) throws -> Bool {
        lock.lock()
        let pendingCommands = commands
        commands.removeAll(keepingCapacity: true)
        var results: [CommandResult] = []
        var shouldStop = false
        for cmd in pendingCommands {
            switch cmd {
            case .attach(let arguments, let continuation):
                handleAttach(arguments, continuation: continuation, results: &results)
            case .detach(let side, let continuation):
                handleDetach(side, continuation: continuation, results: &results)
            case .enableRead(let side, let id):
                handleEnableRead(side, id: id)
            case .enableWrite(let side, let id):
                handleEnableWrite(side, id: id, fdSet: fdSet)
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
        // Prepare fds before processing
        if let link, fdSet.readable.contains(link.fd) {
            try link.prepare?()
        }
        if let tun, fdSet.readable.contains(tun.fd) {
            try tun.prepare?()
        }

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
                } catch let error as IOError {
                    throw error
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            if !inbox.isEmpty {
                let action = try tun.processReadPackets(inbox)
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
                } catch let error as IOError {
                    throw error
                } catch {
                    throw PartoutError(.ioFailure)
                }
            }
            if !inbox.isEmpty {
                let action = try link.processReadPackets(inbox)
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
        scheduleQueue.asyncAfter(deadline: .now() + Self.noBufRetryDelay) { [weak self] in
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
        scheduleQueue.asyncAfter(deadline: .now() + Self.noBufRetryDelay) { [weak self] in
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

    func detachImmediately(_ side: Side, withReason reason: Error?) {
        lock.with {
            switch side {
            case .link:
                link?.detach(reason: reason)
                link = nil
            case .tun:
                tun?.detach(reason: reason)
                tun = nil
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
        guard state != .stopped else {
            lock.unlock()
            assertionFailure("Finishing twice?")
            return
        }
        state = .stopped
        terminalError = error
        lock.unlock()

        if let error {
            stopContinuation?.resume(throwing: error)
        } else {
            stopContinuation?.resume()
        }
        stopContinuation = nil
        onFinish(error)
    }
}

// MARK: - Commands (inside lock)

private extension FdLooper {
    func handleAttach(
        _ arguments: AttachArguments,
        continuation: CheckedContinuation<Void, Error>,
        results: inout [CommandResult]
    ) {
        switch arguments.pair {
        case .link(let linkFd, let ioFd):
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
            guard pp_mux_add(mux, linkFd) else {
                pp_log(ctx, .core, .fault, "Unable to attach link (fd=\(linkFd))")
                results.append(.attach(continuation, .failure(MuxError(side: .link))))
                break
            }
            pp_log(ctx, .core, .info, "Attach link (fd=\(linkFd))")

            // Create new side
            link = SideIO(
                mux: mux,
                linkFd: linkFd,
                ioFd: ioFd,
                readBufSize: linkBufSize,
                arguments: arguments
            )
            results.append(.attach(continuation, .success(())))
        case .tun(let tunFd, let ioFd):
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
            guard pp_mux_add(mux, tunFd) else {
                pp_log(ctx, .core, .fault, "Unable to attach tun (fd=\(tunFd))")
                results.append(.attach(continuation, .failure(MuxError(side: .tun))))
                break
            }
            pp_log(ctx, .core, .info, "Attach tun (fd=\(tunFd))")

            // Create new side
            do {
                tun = try SideIO(
                    mux: mux,
                    tunFd: tunFd,
                    ioFd: ioFd,
                    readBufSize: tunBufSize,
                    arguments: arguments
                )
                results.append(.attach(continuation, .success(())))
            } catch {
                pp_log(ctx, .core, .fault, "Unable to retain tun: \(error)")
                pp_mux_delete(mux, tunFd)
                results.append(.attach(continuation, .failure(MuxError(side: .tun))))
            }
        }
    }

    func handleDetach(
        _ side: Side,
        continuation: CheckedContinuation<Void, Never>,
        results: inout [CommandResult]
    ) {
        switch side {
        case .link:
            link?.detach()
            link = nil
            readRetries.remove(.link)
            writeRetries.remove(.link)
            results.append(.detach(continuation))
        case .tun:
            tun?.detach()
            tun = nil
            readRetries.remove(.tun)
            writeRetries.remove(.tun)
            results.append(.detach(continuation))
        }
    }

    func handleEnableRead(_ side: Side, id: UUID?) {
        if let id {
            guard !isOutdated(id, side: side) else {
                return
            }
        }
        switch side {
        case .link:
            if let link {
                pp_mux_set_read(mux, link.fd, true)
            } else {
                pp_log(ctx, .core, .error, "Ignoring enableRead(.link), not attached")
            }
        case .tun:
            if let tun {
                pp_mux_set_read(mux, tun.fd, true)
            } else {
                pp_log(ctx, .core, .error, "Ignoring enableRead(.tun), not attached")
            }
        }
    }

    func handleEnableWrite(_ side: Side, id: UUID?, fdSet: FdSet) {
        if let id {
            guard !isOutdated(id, side: side) else {
                return
            }
        }
        switch side {
        case .link:
            if let link {
                pp_mux_set_write(mux, link.fd, true)
                fdSet.writable.insert(link.fd)
            } else {
                pp_log(ctx, .core, .error, "Ignoring enableWrite(.link), not attached")
            }
        case .tun:
            if let tun {
                pp_mux_set_write(mux, tun.fd, true)
                fdSet.writable.insert(tun.fd)
            } else {
                pp_log(ctx, .core, .error, "Ignoring enableWrite(.tun), not attached")
            }
        }
    }
}

// MARK: - Descriptors

private final class FdSet {
    var readable: Set<FileDescriptor>
    var writable: Set<FileDescriptor>

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
    struct MuxError: Error {
        let side: Side?
    }

    struct WaitError: Error, CustomDebugStringConvertible {
        let code: Int32

        var debugDescription: String {
            "wait: last_error=\(code)"
        }
    }

    enum IOError: Error, CustomDebugStringConvertible {
        case wouldBlock(Side)
        case noBufSpace(Side)
        case eof(Side)
        case libc(Side, Int32)
        case user(Side, Error? = nil)

        var side: Side {
            switch self {
            case .wouldBlock(let side): side
            case .noBufSpace(let side): side
            case .eof(let side): side
            case .libc(let side, _): side
            case .user(let side, _): side
            }
        }

        var debugDescription: String {
            switch self {
            case .wouldBlock(let side): "\(side): would block"
            case .noBufSpace(let side): "\(side): no buffer space"
            case .eof(let side): "\(side): EOF"
            case .libc(let side, let code): "\(side): last_error=\(code)"
            case .user(let side, let reason): "\(side): user error, \(reason.debugDescription)"
            }
        }
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
        let fd: FileDescriptor

        let transformWrite: TransformWrite?
        private let onRead: OnRead?
        private let onFailure: OnFailure?

        let prepare: (() throws -> Void)?
        private let read: (inout [UInt8]) throws -> Data?
        private let write: (PendingWrite) throws -> Int
        private var cleanup: (() -> Void)?

        private var readBuf: [UInt8]
        private var writeQueue: RingQueue<Data>
        private var writeOffset: Int

        init(
            side: Side,
            fd: FileDescriptor,
            readBufSize: Int,
            arguments: FdLooper.AttachArguments,
            prepare: (() throws -> Void)? = nil,
            read: @escaping (inout [UInt8]) throws -> Data?,
            write: @escaping (PendingWrite) throws -> Int,
            cleanup: @escaping () -> Void,
        ) {
            self.side = side
            self.fd = fd
            transformWrite = arguments.transformWrite
            onRead = arguments.onRead
            onFailure = arguments.onFailure
            self.prepare = prepare
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

        func processReadPackets(_ packets: [Data]) throws -> FdLooper.ReadAction {
            do {
                return try onRead?(packets) ?? .keep
            } catch {
                // IMPORTANT: Wrap user-defined errors to prevent premature finish
                throw IOError.user(side, error)
            }
        }

        func performWrite(_ pending: PendingWrite, lock: SemaphoreMutex) throws -> Bool {
            let count = try write(pending)
            let didComplete = count == pending.count
            lock.with {
                if didComplete {
                    writeQueue.removeFirst()
                    writeOffset = 0
                } else {
                    writeOffset += count
                }
            }
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

        func writeOutOfBand(_ data: Data) throws {
            guard try write(PendingWrite(data)) == data.count else {
                throw PartoutError(.ioFailure)
            }
        }

        func detach(reason: Error? = nil) {
            if let reason {
                onFailure?(reason)
            }
            cleanup?()
            cleanup = nil
        }
    }
}

// MARK: - Link/Tun initializers

extension LinkInterface {
    public var descriptorPair: FdLooper.AttachArguments.DescriptorPair? {
        guard let muxDescriptor else {
            pp_log_g(.core, .fault, "LinkInterface has no .muxDescriptor")
            return nil
        }
        guard let nativeIO else {
            pp_log_g(.core, .fault, "LinkInterface has no .nativeIO")
            return nil
        }
        return .link(muxDescriptor, nativeIO)
    }
}

extension TunInterface {
    public var descriptorPair: FdLooper.AttachArguments.DescriptorPair? {
        guard let muxDescriptor else {
            pp_log_g(.core, .fault, "TunInterface has no .muxDescriptor")
            return nil
        }
        guard let nativeIO else {
            pp_log_g(.core, .fault, "TunInterface has no .nativeIO")
            return nil
        }
        return .tun(muxDescriptor, nativeIO)
    }
}

private extension FdLooper.SideIO {
    convenience init(
        mux: pp_mux,
        linkFd: FileDescriptor,
        ioFd: NativeIOInterface,
        readBufSize: Int,
        arguments: FdLooper.AttachArguments
    ) {
        let closesOnEmptyRead = arguments.closesOnEmptyRead
        self.init(
            side: .link,
            fd: linkFd,
            readBufSize: readBufSize,
            arguments: arguments,
            prepare: {
                guard pp_socket_reset_event(socketFd, linkFd) else {
                    throw FdLooper.IOError.libc(.link, pp_socket_last_error())
                }
            },
            read: { buf in
                let count = ioFd.read(&buf)
                guard count != PPIOErrorWouldBlock else {
                    throw FdLooper.IOError.wouldBlock(.link)
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.libc(.link, ioFd.lastErrorCode)
                }
                guard count > 0 else {
                    if closesOnEmptyRead {
                        throw FdLooper.IOError.eof(.link)
                    }
                    return nil
                }
                return Data(buf[0..<Int(count)])
            },
            write: { pending in
                let count = ioFd.write(pending.data, offset: pending.offset)
                guard count != PPIOErrorWouldBlock else {
                    throw FdLooper.IOError.wouldBlock(.link)
                }
                guard count != PPIOErrorNoBufs else {
                    throw FdLooper.IOError.noBufSpace(.link)
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.libc(.link, ioFd.lastErrorCode)
                }
                return Int(count)
            },
            cleanup: {
                pp_mux_delete(mux, linkFd)
                ioFd.cleanup()
            }
        )
    }

    convenience init(
        mux: pp_mux,
        tunFd: FileDescriptor,
        ioFd: NativeIOInterface,
        readBufSize: Int,
        arguments: FdLooper.AttachArguments
    ) throws {
        self.init(
            side: .tun,
            fd: tunFd,
            readBufSize: readBufSize,
            arguments: arguments,
            read: { buf in
                let count = ioFd.read(&buf)
                guard count != PPIOErrorWouldBlock else {
                    throw FdLooper.IOError.wouldBlock(.tun)
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.libc(.tun, ioFd.lastErrorCode)
                }
                guard count > 0 else {
                    return nil
                }
                return Data(buf[0..<Int(count)])
            },
            write: { pending in
                let count = ioFd.write(pending.data, offset: pending.offset)
                guard count != PPIOErrorWouldBlock else {
                    throw FdLooper.IOError.wouldBlock(.tun)
                }
                guard count != PPIOErrorNoBufs else {
                    throw FdLooper.IOError.noBufSpace(.tun)
                }
                guard count >= 0 else {
                    throw FdLooper.IOError.libc(.tun, ioFd.lastErrorCode)
                }
                return Int(count)
            },
            cleanup: {
                pp_mux_delete(mux, tunFd)
                ioFd.cleanup()
            }
        )
    }
}
