// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !os(Windows)
internal import _PartoutCore_C

/// Loops through a set of file descriptors.
public final class FdLooper: @unchecked Sendable {
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
    private let maxReadSize: Int
    private let maxReadCount: Int

    private let lock: SemaphoreMutex
    private var loopTask: Task<Void, Never>?
    private var commands: [Command]
    private var isStopping: Bool
    private var linkBuf: [UInt8]
    private var tunBuf: [UInt8]

    // Consumer:
    // - Writes to linkQueue/tunQueue .outbound
    // - Reads from linkQueue/tunQueue .inbound
    private var linkQueue: BidirectionalState<[Data]>
    private var tunQueue: BidirectionalState<[Data]>

    public init(
        _ ctx: PartoutLoggerContext,
        link linkInterface: IOInterface,
        tun tunInterface: IOInterface?,
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
        self.maxReadSize = max(maxReadSize, linkBufSize, tunBufSize)
        self.maxReadCount = maxReadCount

        lock = SemaphoreMutex()
        commands = []
        isStopping = false
        link = pp_socket_create(UInt64(linkFd))
        tun = tunFd.map(pp_tun_create)
        linkBuf = Array(repeating: 0, count: linkBufSize)
        tunBuf = Array(repeating: 0, count: tunBufSize)
        linkQueue = BidirectionalState(withResetValue: [])
        tunQueue = BidirectionalState(withResetValue: [])
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        precondition(loopTask == nil, "Call await stop() before releasing InterfaceLooper")

        pp_log(ctx, .core, .debug, "Deinit InterfaceLooper")
        pp_socket_release(link)
        tun.map(pp_tun_release)
        pp_mux_free(mux)
    }

    public func attachTun(_ tunInterface: IOInterface) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.with {
                // Ignore command if not started or stopping
                guard loopTask != nil, !isStopping else {
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
        precondition(loopTask == nil, "Looper already started")

        // Event loop
        loopTask = Task { [weak self] in
            defer {
                pp_log(self?.ctx ?? .global, .core, .info, "Finish looper")
            }
            guard let weakMux = self?.mux else { return }
            nonisolated(unsafe) let mux = weakMux

            // Bind I/O callbacks to fd set
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

            // Fd sets are mutated here and in the waitQueue, but
            // never concurrently, so no locks are needed
            let waitQueue = DispatchQueue(label: "InterfaceLooper.Waiter")
            pp_log(self?.ctx ?? .global, .core, .info, "Start looper")

            // Remember to clean up on task end
            defer {
                Unmanaged<FdSet>.fromOpaque(fdSetCtx).release()
            }

            // Start loop
            while true {
                // Reset readable fds before the wait
                fdSet.resetReadable()

                // Perform the blocking call
                let result = await withCheckedContinuation { continuation in
                    waitQueue.async {
                        let num = pp_mux_wait(mux)
                        continuation.resume(returning: num)
                    }
                }
                guard result >= 0 else {
                    break
                }

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
                }
            }
        }
    }

    public func stop() async {
        let task: Task<Void, Never>?

        // Submit .stop command
        lock.lock()
        task = loopTask
        if task != nil, !isStopping {
            isStopping = true
            commands.append(.stop)
            pp_mux_wake(mux)
        }
        lock.unlock()

        // Wait for task to exit
        await task?.value
        lock.with {
            loopTask = nil
        }
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
                guard !isStopping else {
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
            while let packet = linkQueue.outbound.first {
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
                linkQueue.outbound.removeFirst()
                if count < packet.count {
                    let partialPacket = Data(packet[Int(count)...])
                    linkQueue.outbound.insert(partialPacket, at: 0)
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
            while let packet = tunQueue.outbound.first {
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
                tunQueue.outbound.removeFirst()
                if count < packet.count {
                    let partialPacket = Data(packet[Int(count)...])
                    tunQueue.outbound.insert(partialPacket, at: 0)
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
                    tunQueue.inbound.append(packet)
                }
                // Keep going
                readCount += 1
                readSize += count
            }
        }

        // Read link
        if fdSet.readable.contains(linkFd) {
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
                    linkQueue.inbound.append(packet)
                }
                // Keep going
                readCount += 1
                readSize += count
            }
        }
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
